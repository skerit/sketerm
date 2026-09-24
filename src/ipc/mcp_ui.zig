//! MCP panel tools (ui_*) and the live panel transport: relay through
//! the session's origin daemon, or an explicit direct GUI socket.

const std = @import("std");
const c = @import("../c.zig").c;
const clock = @import("../util/clock.zig");
const platform = @import("../util/platform.zig");
const protocol = @import("protocol.zig");
const muxclient = @import("../mux/client.zig");
const mcp_tools = @import("mcp_tools.zig");
const panelstore = @import("panelstore.zig");
const paneldrive = @import("paneldrive.zig");
const panelrpc = @import("../mux/panelrpc.zig");
const paneldoc = @import("../ui/panel/doc.zig");
const wire = @import("../mux/wire.zig");
const mcp = @import("mcp.zig");
const mcp_testkit = @import("mcp_testkit.zig");
const Backend = mcp.Backend;
const DirectTalkFailure = mcp.DirectTalkFailure;
const EnvSave = mcp_testkit.EnvSave;
const ErrCode = mcp.ErrCode;
const FakeBackend = mcp_testkit.FakeBackend;
const GuiSocketSource = mcp.GuiSocketSource;
const IpcDelivery = mcp.IpcDelivery;
const IpcReply = mcp.IpcReply;
const RealBackend = mcp.RealBackend;
const Res = mcp.Res;
const WAIT_CAP_MS = mcp.WAIT_CAP_MS;
const argBool = mcp.argBool;
const argInt = mcp.argInt;
const argStr = mcp.argStr;
const errRes = mcp.errRes;
const expectToolResultShape = mcp.expectToolResultShape;
const handleMessage = mcp.handleMessage;
const objInt = mcp.objInt;
const objStr = mcp.objStr;
const parseIpcReply = mcp.parseIpcReply;
const reqLine = mcp.reqLine;
const rpcToolResult = mcp.rpcToolResult;
const run = mcp.run;

// ── ui_*: agent-authored UI panels ────────────────────────────────
//
// Live panels are RENDERED BY THE GUI. The same `panel-*` JSON commands
// reach it through either the owning mux session's panel relay or the
// legacy direct control socket; panelstore.zig remains the saved half.
// Two invariants hold it together:
//
// - **Poll here, never block there.** `panel-events` answers
//   immediately by design: it is dispatched on the GLib main loop, and
//   blocking that would freeze every window the user has. So
//   `ui_wait_event`'s BLOCKING semantics live here, as a poll loop.
//   Do not "fix" it by teaching the GUI side to wait.
// - **One session key for both halves.** Several assistants drive one
//   sketerm, so a panel is (session, name). The session is resolved
//   ONCE per call (`panelstore.resolveSession`: explicit arg, else
//   $SKETERM_SESSION, else NONE — `?[]const u8`, never a magic name)
//   and passed explicitly to the GUI, so a live panel and its saved
//   document can never end up under different keys. "No session" is a
//   different SHAPE, not a reserved session name: on the wire it is an
//   empty `session` field (`panelhost.NO_SESSION_WIRE`, distinct from
//   an absent one, which means "scope me to the requesting pane"), and
//   on disk it is its own directory (`panelstore.NO_SESSION_DIR`).
// - **The GUI holds the document; this server holds none.** `ui_save`
//   with no `document` reads the panel back with `panel-get`, so it
//   works against a panel any process showed, at any time. There is
//   deliberately no server-side mirror to go stale.

/// Poll granularity for ui_wait_event. Human interaction latency is
/// orders of magnitude above this, and each tick is one tiny IPC
/// round-trip on the GUI's main loop.
const UI_POLL_MS: u32 = 100;

const UI_WAIT_DEFAULT_MS: i64 = 30_000;

const UI_NEEDS_TRANSPORT =
    "no live panel transport is available. From a sketerm pane, preserve SKETERM_SESSION and " ++
    "SKETERM_MUX_SOCKET so ui_* can relay through that exact mux session; sessionless/legacy callers " ++
    "can use an explicit --socket <GUI path>. The MCP app tools remain on their private daemon. " ++
    "ui_save with a document, ui_panels' saved half, and ui_delete still work without a live viewer.";

/// `ui_save` with no document reads the panel back from the GUI
/// (`panel-get`), which is why this server keeps no document state of
/// its own.
const UI_SAVE_NEEDS_TRANSPORT =
    "ui_save without 'document' reads the panel's CURRENT document back from the sketerm GUI, " ++
    "but no live panel transport is available. Either pass 'document' explicitly, run with the originating " ++
    "SKETERM_SESSION + SKETERM_MUX_SOCKET, or use an explicit --socket for a sessionless/legacy GUI. " ++
    "`capabilities` reports `panels`, `panel_transport`, and `gui_socket` separately.";

const UI_RELAY_CALL_MS: i64 = 40_000;

/// `capabilities` is a preflight: its liveness probe must cost a moment, not
/// a whole tool call's budget.
pub const UI_CAPABILITY_PROBE_MS: i64 = 2_000;

/// Cap on `ui_show_files`. Well under doc.MAX_CHILDREN (128, and the
/// heading takes one), and past a few dozen images a scrolling column
/// is the wrong presentation anyway.
const UI_FILES_MAX: usize = 64;

/// Default panel name for `ui_show_files`, so the common call is
/// genuinely one line. Re-showing it replaces the panel in place,
/// which is what "here is the next epoch" wants.
const UI_FILES_NAME = "files";

/// One entry of `ui_show_files`: an absolute image path plus the
/// caption drawn under it (or, in compare mode, its side label).
const UiFile = struct { path: []const u8, caption: []const u8 };

/// Build the panel document `ui_show_files` shows. Pure — no IPC, no
/// disk — so "the generator emits a document the parser accepts" is a
/// unit-testable property rather than a GUI-side refusal.
fn uiFilesDocument(
    arena: std.mem.Allocator,
    files: []const UiFile,
    title: []const u8,
    compare: bool,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    const heading = title.len > 0;

    try w.writeAll("{\"version\":1,\"title\":");
    try std.json.Stringify.value(if (heading) title else "Images", .{}, w);
    try w.writeAll(",\"root\":\"main\",\"components\":{\"main\":{\"type\":\"column\",\"children\":[");
    if (heading) try w.writeAll("\"h\"");
    if (compare) {
        if (heading) try w.writeByte(',');
        try w.writeAll("\"cmp\"");
    } else for (files, 0..) |_, i| {
        if (heading or i > 0) try w.writeByte(',');
        try w.print("\"img{d}\"", .{i + 1});
    }
    try w.writeAll("]}");

    if (heading) {
        try w.writeAll(",\"h\":{\"type\":\"heading\",\"level\":2,\"text\":");
        try std.json.Stringify.value(title, .{}, w);
        try w.writeByte('}');
    }
    if (compare) {
        try w.writeAll(",\"cmp\":{\"type\":\"image_compare\",\"left\":{\"src\":");
        try std.json.Stringify.value(files[0].path, .{}, w);
        try w.writeAll(",\"label\":");
        try std.json.Stringify.value(files[0].caption, .{}, w);
        try w.writeAll("},\"right\":{\"src\":");
        try std.json.Stringify.value(files[1].path, .{}, w);
        try w.writeAll(",\"label\":");
        try std.json.Stringify.value(files[1].caption, .{}, w);
        try w.writeAll("}}");
    } else for (files, 0..) |f, i| {
        try w.print(",\"img{d}\":{{\"type\":\"image\",\"src\":", .{i + 1});
        try std.json.Stringify.value(f.path, .{}, w);
        try w.writeAll(",\"caption\":");
        try std.json.Stringify.value(f.caption, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("}}");
    return aw.written();
}

/// The session a ui_* call is scoped to — `null` when there is none.
/// Resolved ONCE per call and passed explicitly to both halves, so a
/// live panel and its saved document cannot land under different keys.
fn uiSession(args: std.json.Value) error{InvalidSessionType}!?[]const u8 {
    if (args == .object) {
        if (args.object.get("session")) |value| {
            if (value == .string) return panelstore.resolveSession(.{ .explicit = value.string });
            return error.InvalidSessionType;
        }
    }
    return panelstore.resolveSession(.absent);
}

/// The scope as the control socket spells it: an EMPTY `session`
/// states "this caller has no session", which the GUI must not confuse
/// with an absent field (= scope me to the requesting pane).
pub fn uiWireSession(session: ?[]const u8) []const u8 {
    return session orelse "";
}

const UiStoreScope = struct {
    scope: panelstore.Scope = .sessionless,
    err: []const u8 = "",
};

pub const UiTransport = struct {
    arena: std.mem.Allocator,
    backend: Backend,
    session: ?[]const u8,
    mode: enum { auto, mux_relay, gui_socket, none },
    origin: ?paneldrive.Origin = null,
    failure: ?paneldrive.Failure = null,
    validated_store_scope: ?panelstore.Scope = null,

    pub fn init(arena: std.mem.Allocator, backend: Backend, session: ?[]const u8) UiTransport {
        const exact_origin = session != null and paneldrive.hasEnvironmentSocket();
        return .{
            .arena = arena,
            .backend = backend,
            .session = session,
            .mode = if (exact_origin)
                if (mcp.panel_pool != null) .auto else .none
            else if (mcp.srv_gui_socket_source == .explicit)
                .gui_socket
            else if (session != null and mcp.panel_pool != null)
                .auto
            else if (mcp.srv_gui_socket)
                .gui_socket
            else
                .none,
        };
    }

    pub fn deinit(self: *UiTransport) void {
        if (self.origin) |*origin| origin.deinit(self.arena);
        self.origin = null;
    }

    pub fn selected(self: *const UiTransport) []const u8 {
        return switch (self.mode) {
            .auto, .mux_relay => "mux_relay",
            .gui_socket => "gui_socket",
            .none => "none",
        };
    }

    pub fn source(self: *const UiTransport) []const u8 {
        return switch (self.mode) {
            .gui_socket => switch (mcp.srv_gui_socket_source) {
                .explicit => "gui_socket_explicit",
                .discovered => "gui_socket_discovered",
                .none => "none",
            },
            .auto, .mux_relay => if (self.origin) |origin| switch (origin.source) {
                .environment => "SKETERM_MUX_SOCKET",
                .default_compat => "default_socket_connect_only",
            } else "none",
            .none => "none",
        };
    }

    pub fn talk(self: *UiTransport, req: protocol.Request) IpcReply {
        return self.talkFor(req, UI_RELAY_CALL_MS);
    }

    pub fn talkFor(self: *UiTransport, req: protocol.Request, timeout_ms: i64) IpcReply {
        const deadline_ms = clock.nowMs() + @max(timeout_ms, 0);
        switch (self.mode) {
            .gui_socket => return self.directUntil(req, deadline_ms),
            .none => return .{ .ok = false, .value = .null, .err = UI_NEEDS_TRANSPORT, .code = .unavailable },
            .mux_relay, .auto => return self.relayUntil(req, deadline_ms),
        }
    }

    pub fn directUntil(self: *UiTransport, req: protocol.Request, deadline_ms: i64) IpcReply {
        const remain = deadline_ms - clock.nowMs();
        if (remain <= 0) return .{
            .ok = false,
            .value = .null,
            .err = "the shared panel deadline expired before direct fallback delivery; failure_class=pre_delivery, mutation_may_have_applied=false, resend_safe=true",
            .delivery = .pre_delivery,
        };
        const line = reqLine(self.arena, req) catch
            return .{ .ok = false, .value = .null, .err = "could not encode the panel request", .code = .failed };
        const response = switch (self.backend.talkFor(self.backend.ctx, self.arena, line, remain)) {
            .reply => |reply| reply,
            .failure => |failure| return .{
                .ok = false,
                .value = .null,
                .err = directFailureMessage(self.arena, req.cmd, failure),
                .delivery = switch (failure.delivery) {
                    .pre_delivery => .pre_delivery,
                    .uncertain_delivery => .uncertain_delivery,
                },
            },
        };
        const meta = panelrpc.validateReply(self.arena, panelrpc.opFromCommand(req.cmd), response) catch |err| return .{
            .ok = false,
            .value = .null,
            .err = std.fmt.allocPrint(
                self.arena,
                "the direct GUI presenter returned an invalid {s} reply after request delivery ({s}); delivery is uncertain, the mutation may have applied, and the request was NOT resent",
                .{ req.cmd, @errorName(err) },
            ) catch "the direct GUI presenter returned an invalid reply after uncertain delivery; the request was not resent",
            .delivery = .uncertain_delivery,
        };
        const parsed = parseIpcReply(self.arena, response);
        if (meta.uncertain_delivery) return .{
            .ok = false,
            .value = .null,
            .err = std.fmt.allocPrint(
                self.arena,
                "the direct GUI presenter reported failure_class=uncertain_delivery ({s}); delivery is uncertain, the mutation may have applied, and it was NOT resent automatically. Do not resend it automatically",
                .{parsed.err},
            ) catch "the direct GUI presenter reported uncertain delivery; the mutation may have applied and it was not resent",
            .delivery = .uncertain_delivery,
        };
        return parsed;
    }

    pub fn direct(self: *UiTransport, req: protocol.Request, timeout_ms: i64) IpcReply {
        return self.directUntil(req, clock.nowMs() + @max(timeout_ms, 0));
    }

    /// Validate and retain persistence identity before a live request can fail.
    pub fn prepareStoreScopeUntil(
        self: *UiTransport,
        origin: paneldrive.Origin,
        deadline_ms: i64,
    ) ?paneldrive.Failure {
        if (self.validated_store_scope != null) return null;
        if (origin.source == .environment) switch (paneldrive.environmentIdentity(origin.session)) {
            .exact => |origin_id| {
                self.validated_store_scope = .{ .origin = .{
                    .daemon_origin = origin.socket,
                    .origin_id = origin_id,
                    .label = origin.session,
                } };
                return null;
            },
            .malformed => return .{
                .kind = .malformed_attach,
                .detail = "MalformedInheritedOriginId",
            },
            .none => {},
        };
        const pool = mcp.panel_pool orelse return .{
            .kind = .unsupported,
            .detail = "PanelRelayUnavailable",
        };
        const outcome = pool.identifyUntil(self.arena, origin, deadline_ms) catch return .{
            .kind = .allocation_failed,
            .detail = "OutOfMemory",
        };
        switch (outcome) {
            .identity => |identity| {
                self.validated_store_scope = .{ .origin = .{
                    .daemon_origin = identity.daemon_origin,
                    .origin_id = identity.origin_id,
                    .label = origin.session,
                } };
                return null;
            },
            .failure => |failure| {
                // A daemon with no lifetime id cannot key an exact scope, so
                // the session name is the best identity available. Anything
                // else leaves the scope unresolved rather than guessing.
                if (failure.kind == .legacy_daemon or origin.source == .default_compat)
                    self.validated_store_scope = .{ .session = origin.session };
                return failure;
            },
        }
    }

    pub fn relayUntil(self: *UiTransport, req: protocol.Request, deadline_ms: i64) IpcReply {
        if (self.origin == null) {
            self.origin = paneldrive.Origin.resolve(self.arena, self.session) catch {
                self.mode = .none;
                return .{ .ok = false, .value = .null, .err = UI_NEEDS_TRANSPORT, .code = .unavailable };
            };
        }
        const origin = self.origin.?;
        const line = reqLine(self.arena, req) catch
            return .{ .ok = false, .value = .null, .err = "could not encode the panel request", .code = .failed };
        const pool = mcp.panel_pool orelse {
            self.mode = .none;
            return .{ .ok = false, .value = .null, .err = UI_NEEDS_TRANSPORT, .code = .unavailable };
        };
        if (self.prepareStoreScopeUntil(origin, deadline_ms)) |failure| {
            if (self.canFallbackDirect(origin, failure)) {
                self.failure = failure;
                self.mode = .gui_socket;
                return self.directUntil(req, deadline_ms);
            }
            self.failure = failure;
            self.mode = .mux_relay;
            return .{
                .ok = false,
                .value = .null,
                .err = relayFailure(self.arena, origin, failure),
                .delivery = .pre_delivery,
            };
        }
        // The relay validated this reply against the same op on the way in:
        // `panelrpc.validateReply` runs once, in paneldrive, and a bad shape
        // arrives here as a failure rather than as a reply to re-check.
        const outcome = pool.callUntil(self.arena, origin, panelrpc.opFromCommand(req.cmd), line, deadline_ms) catch
            return .{ .ok = false, .value = .null, .err = "panel relay ran out of memory", .code = .failed };
        switch (outcome) {
            .reply => |reply| {
                self.mode = .mux_relay;
                const parsed = parseIpcReply(self.arena, reply.json);
                if (reply.pre_delivery and !parsed.ok) return .{
                    .ok = false,
                    .value = parsed.value,
                    .err = std.fmt.allocPrint(
                        self.arena,
                        "{s}; failure_class=pre_delivery, mutation_may_have_applied=false, resend_safe=true",
                        .{parsed.err},
                    ) catch parsed.err,
                    .delivery = .pre_delivery,
                };
                return parsed;
            },
            .failure => |failure| {
                if (self.canFallbackDirect(origin, failure)) {
                    self.failure = failure;
                    self.mode = .gui_socket;
                    return self.directUntil(req, deadline_ms);
                }
                self.failure = failure;
                self.mode = .mux_relay;
                return .{
                    .ok = false,
                    .value = .null,
                    .err = relayFailure(self.arena, origin, failure),
                    .delivery = if (failure.uncertain()) .uncertain_delivery else .pre_delivery,
                };
            },
        }
    }

    pub fn canFallbackDirect(_: *const UiTransport, origin: paneldrive.Origin, failure: paneldrive.Failure) bool {
        if (origin.source != .environment or mcp.srv_gui_socket_source != .explicit) return false;
        return switch (failure.kind) {
            .legacy_daemon, .unsupported, .no_compatible_gui, .attach_failed, .malformed_attach => true,
            .no_such_session => false,
            else => false,
        };
    }
};

/// Resolve the saved-panel scope, spending at most `budget_ms` on the
/// identity probe it may have to make.
pub fn uiStoreScope(transport: *UiTransport, budget_ms: i64) UiStoreScope {
    const session = transport.session orelse return .{ .scope = .sessionless };
    // With no exact daemon to key on, the session name is the whole identity.
    const by_session = UiStoreScope{ .scope = .{ .session = session } };

    if (transport.mode == .gui_socket and transport.origin == null and !paneldrive.hasEnvironmentSocket())
        return by_session;
    if (transport.origin == null) {
        transport.origin = paneldrive.Origin.resolve(transport.arena, session) catch |err| {
            if (!paneldrive.hasEnvironmentSocket()) return by_session;
            return .{ .err = std.fmt.allocPrint(
                transport.arena,
                "could not canonicalize the exact SKETERM_MUX_SOCKET persistence origin ({s}); refusing reusable (socket,session) storage",
                .{@errorName(err)},
            ) catch "could not canonicalize the exact persistence origin; refusing reusable storage" };
        };
    }
    const origin = transport.origin.?;
    if (transport.validated_store_scope) |scope| return .{ .scope = scope };
    if (origin.source == .default_compat and (mcp.panel_pool == null or transport.mode == .none))
        return by_session;

    // An inherited $SKETERM_MUX_SOCKET names one exact daemon. If its lifetime
    // identity cannot be established, say so instead of silently writing into
    // the (socket, session) namespace a later same-name session would share.
    const failure = transport.failure orelse
        transport.prepareStoreScopeUntil(origin, clock.nowMs() + @max(budget_ms, 0));
    if (transport.validated_store_scope) |scope| return .{ .scope = scope };
    if (origin.source != .environment) return by_session;
    if (failure) |f| return .{ .err = uiStoreFailure(transport.arena, origin, f) };
    return .{
        .err = "exact saved-panel identity validation completed without a scope; refusing to downgrade to reusable (socket,session) storage",
    };
}

fn uiStoreFailure(arena: std.mem.Allocator, origin: paneldrive.Origin, failure: paneldrive.Failure) []const u8 {
    const reason: []const u8 = switch (failure.kind) {
        // A legacy daemon always retains a by-session scope in
        // `prepareStoreScopeUntil`, so it can only reach this switch as the
        // same "no compatible exact identity" story `unsupported` tells.
        .legacy_daemon, .unsupported => "the daemon cannot expose a compatible exact lifetime identity",
        .no_compatible_gui => "no compatible GUI was available before exact identity validation",
        .no_such_session => "the exact session is no longer present",
        .origin_unreachable => "the exact daemon is unreachable",
        .origin_timeout => "exact daemon identity validation timed out",
        .attach_failed => "the exact session attach failed",
        .identity_mismatch => "the session lifetime identity does not match",
        .malformed_attach => "the inherited or attached session lifetime identity is malformed",
        .malformed_welcome => "the daemon capability welcome is malformed",
        .request_too_large => "identity validation reported an impossible oversized request",
        .allocation_failed => "identity validation ran out of memory",
        .send_pre_delivery => "identity validation transport failed before delivery",
        .delivery_uncertain => "identity validation delivery is uncertain",
        .reply_timeout => "identity validation reply timed out after delivery",
        .disconnected => "identity validation disconnected after delivery",
        .malformed_reply => "identity validation received a malformed reply after delivery",
    };
    return std.fmt.allocPrint(
        arena,
        "saved-panel persistence scope for exact origin {s} session {s} is unavailable: {s} ({s}: {s}); refusing to downgrade to reusable (socket,session) storage",
        .{ origin.socket, origin.session, reason, @tagName(failure.kind), failure.detail },
    ) catch "saved-panel exact persistence identity is unavailable; refusing reusable (socket,session) storage";
}

fn relayFailure(arena: std.mem.Allocator, origin: paneldrive.Origin, failure: paneldrive.Failure) []const u8 {
    return switch (failure.kind) {
        .legacy_daemon, .unsupported => std.fmt.allocPrint(
            arena,
            "the origin mux daemon does not support panel relay ({s}); update it, or use an explicit direct GUI --socket for legacy operation",
            .{failure.detail},
        ) catch "the origin mux daemon does not support panel relay",
        .no_compatible_gui => std.fmt.allocPrint(
            arena,
            "no compatible GUI is attached to origin session {s}; the request failed before presenter delivery",
            .{origin.session},
        ) catch "no compatible GUI is attached to the origin session",
        .no_such_session => std.fmt.allocPrint(
            arena,
            "origin session {s} is no longer present on its exact daemon ({s})",
            .{ origin.session, failure.detail },
        ) catch "the exact origin session is no longer present",
        .origin_unreachable => std.fmt.allocPrint(
            arena,
            "the origin mux daemon at {s} is unavailable ({s}). It was selected exactly and was not autostarted or replaced, so the MCP private app daemon remains isolated",
            .{ origin.socket, failure.detail },
        ) catch "the origin mux daemon is unavailable",
        .origin_timeout => std.fmt.allocPrint(
            arena,
            "the origin mux daemon at {s} did not complete identity negotiation before the deadline ({s}); it was selected exactly and no replacement was used",
            .{ origin.socket, failure.detail },
        ) catch "the exact origin mux daemon identity negotiation timed out",
        .attach_failed => std.fmt.allocPrint(
            arena,
            "the origin daemon refused a panel-only attachment to session {s} ({s}); the session may have ended",
            .{ origin.session, failure.detail },
        ) catch "the origin daemon refused the panel attachment",
        .identity_mismatch => std.fmt.allocPrint(
            arena,
            "the origin daemon refused session {s} because its lifetime identity changed ({s}); this is a same-name replacement and direct GUI fallback is forbidden",
            .{ origin.session, failure.detail },
        ) catch "the origin session lifetime identity changed; direct fallback is forbidden",
        .malformed_attach => std.fmt.allocPrint(
            arena,
            "the exact origin has malformed inherited or panel-only attachment identity ({s}); immutable origin_name plus lifetime-unique origin_id are required and no requested-alias substitute was used",
            .{failure.detail},
        ) catch "the exact origin has malformed lifetime identity metadata",
        .malformed_welcome => std.fmt.allocPrint(
            arena,
            "the origin daemon returned malformed capability negotiation ({s}); it was not classified as a legacy daemon and no fallback identity was assumed",
            .{failure.detail},
        ) catch "the origin daemon returned malformed capability negotiation",
        .request_too_large, .allocation_failed, .send_pre_delivery => std.fmt.allocPrint(
            arena,
            "the mux panel request failed before any request bytes were delivered ({s}: {s}); failure_class=pre_delivery, mutation_may_have_applied=false, resend_safe=true",
            .{ @tagName(failure.kind), failure.detail },
        ) catch "the mux panel request failed before delivery; resend_safe=true",
        .delivery_uncertain, .reply_timeout, .disconnected, .malformed_reply => std.fmt.allocPrint(
            arena,
            "the mux panel request failed after delivery became uncertain ({s}: {s}); the mutation may have applied and it was NOT resent automatically. Do not resend it automatically",
            .{ @tagName(failure.kind), failure.detail },
        ) catch "the mux panel request failed after uncertain delivery; the mutation may have applied and it was not resent",
    };
}

fn directFailureMessage(arena: std.mem.Allocator, command: []const u8, failure: DirectTalkFailure) []const u8 {
    if (failure.delivery == .pre_delivery) return std.fmt.allocPrint(
        arena,
        "the direct GUI request failed before any request bytes were written ({s}); failure_class=pre_delivery, mutation_may_have_applied=false, resend_safe=true",
        .{@errorName(failure.err)},
    ) catch "the direct GUI request failed before delivery; resend_safe=true";
    if (std.mem.eql(u8, command, "panel-events-reliable")) return std.fmt.allocPrint(
        arena,
        "the direct GUI panel-events-reliable request was written but its reply was lost ({s}); failure_class=uncertain_delivery, events_may_have_been_drained=false, resend_safe=true. The reliable read only acknowledges what an EARLIER reply delivered, so the events it carried are still queued and the next ui_wait_event re-reads them",
        .{@errorName(failure.err)},
    ) catch "the direct GUI event reply was lost; nothing was consumed and the next ui_wait_event re-reads it";
    if (std.mem.eql(u8, command, "panel-events")) return std.fmt.allocPrint(
        arena,
        "the direct GUI panel-events request was partially or fully written but its reply was lost ({s}); failure_class=uncertain_delivery, events_may_have_been_drained=true, resend_safe=false. Events may have been drained by the lost reply; the request was NOT retried automatically",
        .{@errorName(failure.err)},
    ) catch "the direct GUI event reply was lost; events may have been drained and the request was not retried";
    const mutation = std.mem.eql(u8, command, "panel-show") or
        std.mem.eql(u8, command, "panel-patch") or
        std.mem.eql(u8, command, "panel-close");
    if (mutation) return std.fmt.allocPrint(
        arena,
        "the direct GUI mutation was partially or fully written but its reply was lost ({s}); failure_class=uncertain_delivery, mutation_may_have_applied=true, resend_safe=false. The request was NOT retried automatically",
        .{@errorName(failure.err)},
    ) catch "the direct GUI mutation reply was lost after delivery became uncertain; the request was not retried";
    return std.fmt.allocPrint(
        arena,
        "the direct GUI request was partially or fully written but its reply was lost ({s}); failure_class=uncertain_delivery, resend_safe=false. The request was NOT retried automatically",
        .{@errorName(failure.err)},
    ) catch "the direct GUI reply was lost after delivery became uncertain; the request was not retried";
}

/// A failed panel round trip as a typed error. The message is the
/// transport's own (it names the exact origin, session and phase); the
/// CODE comes from the delivery phase first, then from the reply's
/// structured code (`mcp.guiErrCode`, which reads prose only from GUIs
/// too old to send one).
fn uiFailCode(reply: IpcReply) ErrCode {
    return switch (reply.delivery) {
        .pre_delivery => .unavailable,
        .uncertain_delivery => .io_failed,
        .ordinary => mcp.guiErrCode(reply),
    };
}

fn uiTransportErr(arena: std.mem.Allocator, reply: IpcReply) ![]const u8 {
    return errRes(arena, uiFailCode(reply), reply.err);
}

/// The one shape `ui_wait_event` answers with, whether it timed out or
/// carried interactions: the events are machine facts, and the text
/// lane is one line per interaction. A timeout is a FACT, never a tool
/// error — the panel is still showing.
fn uiEventsResult(
    arena: std.mem.Allocator,
    panel_id: u32,
    waited_ms: i64,
    events: ?std.json.Value,
    dropped: i64,
    timeout_ms: i64,
    read: EventRead,
) ![]const u8 {
    var res = Res.init(arena);
    try res.fact("panel_id", panel_id);
    try res.fact("waited_ms", waited_ms);
    try res.fact("dropped", dropped);
    try res.fact("reliable", read == .reliable);

    const items: []const std.json.Value = if (events) |e|
        (if (e == .array) e.array.items else &.{})
    else
        &.{};
    if (events) |e| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        try std.json.Stringify.value(e, .{}, &aw.writer);
        try res.raw("events", aw.written());
    } else try res.raw("events", "[]");
    try res.fact("count", items.len);
    try res.fact("timed_out", items.len == 0);

    if (items.len == 0)
        try res.textf("no interaction within {d}ms — the panel is still showing; wait again or ui_patch it", .{timeout_ms})
    else
        try res.textf("{d} interaction(s) after {d}ms", .{ items.len, waited_ms });
    if (dropped > 0)
        try res.textf("the panel's event queue overflowed and {d} OLDER interaction(s) were discarded; this reply is not the complete history", .{dropped});
    if (items.len > 0) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        for (items, 0..) |ev, i| {
            if (i > 0) try w.writeAll("\n");
            try w.print("{d} {s} {s}", .{ objInt(ev, "seq"), objStr(ev, "kind"), objStr(ev, "component") });
            const v = if (ev == .object) ev.object.get("value") else null;
            if (v) |value| switch (value) {
                .null => {},
                .string => |sv| try w.print(" = {s}", .{sv}),
                .bool => |bv| try w.print(" = {}", .{bv}),
                .integer => |iv| try w.print(" = {d}", .{iv}),
                .float => |fv| try w.print(" = {d}", .{fv}),
                else => {},
            };
        }
        try res.textf("--- events ---\n{s}", .{aw.written()});
    }
    return res.finish();
}

/// A panel that could not be ADDRESSED, typed by the resolver.
fn uiResolveErr(arena: std.mem.Allocator, target: UiResolved) ![]const u8 {
    return errRes(arena, target.code, target.err);
}

/// An argument that may be given either as a JSON value (the natural
/// way for an assistant to write a document) or as a JSON string (the
/// way the control socket carries it). Returns the raw JSON text.
fn uiJsonArg(arena: std.mem.Allocator, args: std.json.Value, key: []const u8) !?[]const u8 {
    if (args != .object) return null;
    const v = args.object.get(key) orelse return null;
    return switch (v) {
        .null => null,
        .string => |s| s,
        else => blk: {
            var aw: std.Io.Writer.Allocating = .init(arena);
            std.json.Stringify.value(v, .{}, &aw.writer) catch return error.OutOfMemory;
            break :blk aw.written();
        },
    };
}

/// One IPC round-trip whose transport failure is a described error
/// rather than a JSON-RPC fault — a GUI that went away mid-flow is a
/// normal thing for an assistant to be told about.
fn uiTalk(transport: *UiTransport, req: protocol.Request) IpcReply {
    return transport.talk(req);
}

const UiResolved = struct {
    id: u32 = 0,
    /// Non-empty when the panel could not be addressed.
    err: []const u8 = "",
    code: ErrCode = .failed,
};

/// Resolve `panel_id`, or look a `name` up in the session's live
/// panels. Name is the stable address; panel_id is what ui_show hands
/// back and what the control socket speaks.
fn uiResolve(
    arena: std.mem.Allocator,
    transport: *UiTransport,
    args: std.json.Value,
    session: ?[]const u8,
) UiResolved {
    return uiResolveFor(arena, transport, args, session, UI_RELAY_CALL_MS);
}

fn uiResolveFor(
    arena: std.mem.Allocator,
    transport: *UiTransport,
    args: std.json.Value,
    session: ?[]const u8,
    timeout_ms: i64,
) UiResolved {
    if (argInt(args, "panel_id")) |pid| {
        if (pid <= 0 or pid > std.math.maxInt(u32))
            return .{ .err = "panel_id must be a positive integer (the handle ui_show returned)", .code = .invalid_args };
        return .{ .id = @intCast(pid) };
    }
    const name = argStr(args, "name") orelse
        return .{ .err = "address the panel by 'name' (stable, preferred) or by 'panel_id'", .code = .invalid_args };

    if (timeout_ms <= 0) return .{ .err = "ui_wait_event's deadline expired while resolving the panel", .code = .timeout };
    const reply = transport.talkFor(.{ .cmd = "panel-list", .session = uiWireSession(session) }, timeout_ms);
    if (!reply.ok) return .{ .err = reply.err, .code = uiFailCode(reply) };
    const panels = reply.value.object.get("panels") orelse
        return .{ .err = "malformed panel-list reply", .code = .io_failed };
    if (panels == .array) {
        for (panels.array.items) |p| {
            if (p != .object) continue;
            const n = p.object.get("name") orelse continue;
            if (n != .string or !std.mem.eql(u8, n.string, name)) continue;
            const idv = p.object.get("panel_id") orelse continue;
            if (idv == .integer and idv.integer > 0) return .{ .id = @intCast(idv.integer) };
        }
    }
    return .{ .code = .not_found, .err = std.fmt.allocPrint(
        arena,
        "no LIVE panel named \"{s}\" in session {s}. `ui_panels` lists what is on screen and what is saved; `ui_show` opens one (with load=\"{s}\" if it is saved).",
        .{ name, panelstore.sessionLabel(session), name },
    ) catch "no live panel with that name" };
}

/// The live document behind a panel, canonically serialized, straight
/// from the GUI's own `doc.Document`. Any panel is readable this way —
/// including one another process showed, or one shown before this
/// server started.
fn uiLiveDocument(
    transport: *UiTransport,
    id: u32,
    session: ?[]const u8,
) struct { json: []const u8 = "", err: []const u8 = "" } {
    const reply = uiTalk(transport, .{
        .cmd = "panel-get",
        .panel_id = id,
        .session = uiWireSession(session),
    });
    if (!reply.ok) return .{ .err = reply.err };
    const dv = reply.value.object.get("document") orelse
        return .{ .err = "panel-get answered without a document" };
    if (dv != .string) return .{ .err = "panel-get answered with a malformed document" };
    return .{ .json = dv.string };
}

/// The remote-image hydration report the GUI attaches to a panel
/// mutation: facts in structuredContent, and ONE situational text line
/// when something failed (a placeholder the user will see).
fn addUiAssetFacts(res: *Res, arena: std.mem.Allocator, reply: IpcReply) !void {
    if (reply.value != .object) return;
    const report = reply.value.object.get("assets") orelse return;
    if (report != .array) return;
    var aw: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(report, .{}, &aw.writer);
    try res.raw("assets", aw.written());
    const failures = reply.value.object.get("asset_failures");
    if (failures == null or failures.? != .integer) return;
    try res.fact("asset_failures", failures.?.integer);
    if (failures.?.integer > 0)
        try res.textf(
            "{d} remote image(s) could not be hydrated; the panel shows explicit placeholders and each failed logical path is listed in assets",
            .{failures.?.integer},
        );
}

/// panelstore failure → the store's own diagnostic (which names the
/// offending panel or component) with the tool-level next step added.
fn uiStoreErr(
    arena: std.mem.Allocator,
    err: panelstore.Error,
    diag: *const paneldoc.Diag,
    what: []const u8,
) ![]const u8 {
    const detail = if (diag.len > 0) diag.msg() else @errorName(err);
    const hint: []const u8 = switch (err) {
        error.NotFound => " — `ui_panels` lists the saved documents in this session",
        error.Corrupt => " — the stored file no longer parses; re-save it with ui_save",
        error.Invalid => " — fix the document and re-send; nothing was written",
        error.TooMany => " — delete one with ui_delete",
        else => "",
    };
    const msg = std.fmt.allocPrint(arena, "{s}: {s}{s}", .{ what, detail, hint }) catch
        return error.OutOfMemory;
    return errRes(arena, uiStoreErrCode(err), msg);
}

/// A panelstore refusal as one of the shared codes.
fn uiStoreErrCode(err: panelstore.Error) ErrCode {
    return switch (err) {
        error.NotFound => .not_found,
        error.Invalid => .invalid_args,
        error.TooMany => .conflict,
        else => .io_failed,
    };
}

fn uiStoreMutationErr(
    arena: std.mem.Allocator,
    err: panelstore.Error,
    diag: *const paneldoc.Diag,
    what: []const u8,
    mutation: []const u8,
) ![]const u8 {
    const detail = if (diag.len > 0) diag.msg() else @errorName(err);
    const hint: []const u8 = switch (err) {
        error.NotFound => " — `ui_panels` lists the saved documents in this session",
        error.Invalid => " — fix the document and re-send; nothing was written",
        error.TooMany => " — delete one with ui_delete",
        else => "",
    };
    // Store mutations are staged then renamed, so a failure never leaves a
    // partial document: it either happened or it did not. That verdict is
    // stated the way every other panel failure states it — as prose the
    // assistant reads, in the same key=value spelling.
    const message = std.fmt.allocPrint(
        arena,
        "{s}: {s}{s} ({s}); mutation={s}, failure_class=pre_commit, mutation_state=not_applied, mutation_may_have_applied=false, committed=false, resend_safe=true",
        .{ what, detail, hint, @errorName(err), mutation },
    ) catch return error.OutOfMemory;
    return errRes(arena, uiStoreErrCode(err), message);
}

pub const Tool = mcp_tools.GroupTool(.ui);

pub fn uiTool(arena: std.mem.Allocator, backend: Backend, tool: Tool, args: std.json.Value) ![]const u8 {
    const session = uiSession(args) catch
        return errRes(arena, .invalid_args, "'session' must be a string when present; omit it to use SKETERM_SESSION, or pass an explicit empty string for sessionless scope");
    var transport = UiTransport.init(arena, backend, session);
    defer transport.deinit();
    return switch (tool) {
        .ui_show => uiShow(arena, args, &transport, session),
        .ui_show_files => uiShowFiles(arena, args, &transport, session),
        .ui_patch => uiPatch(arena, args, &transport, session),
        .ui_wait_event => uiWaitEvent(arena, args, &transport, session),
        .ui_panels => uiPanels(arena, args, &transport, session),
        .ui_save => uiSave(arena, args, &transport, session),
        .ui_close => uiClose(arena, args, &transport, session),
        .ui_delete => uiDelete(arena, args, &transport, session),
    };
}

fn uiShow(arena: std.mem.Allocator, args: std.json.Value, transport: *UiTransport, session: ?[]const u8) ![]const u8 {
    const panel_name = argStr(args, "name") orelse
        return errRes(arena, .invalid_args, "ui_show requires 'name' (the panel's identity in this session)");
    const inline_doc = try uiJsonArg(arena, args, "document");
    const load_name = argStr(args, "load");
    if (inline_doc != null and load_name != null)
        return errRes(arena, .invalid_args, "pass either 'document' (an inline document) or 'load' (a saved one), not both");

    var diag = paneldoc.Diag{};
    const document = inline_doc orelse blk: {
        const saved = load_name orelse
            return errRes(arena, .invalid_args, "ui_show requires 'document' (the panel to render) or 'load' (the name of a document saved with ui_save)");
        const store = uiStoreScope(transport, UI_RELAY_CALL_MS);
        if (store.err.len > 0) return errRes(arena, .unavailable, store.err);
        break :blk panelstore.loadJsonScoped(arena, store.scope, saved, &diag) catch |err|
            return uiStoreErr(arena, err, &diag, "ui_show could not load the saved panel");
    };

    const target = argStr(args, "target") orelse "tab";
    const reply = uiTalk(transport, .{
        .cmd = "panel-show",
        .name = panel_name,
        .session = uiWireSession(session),
        .target = target,
        .document = document,
    });
    // A rejected document answers with doc.Diag's own message,
    // VERBATIM: it names the offending component id, and that text
    // is how the assistant fixes what it wrote.
    if (!reply.ok) return uiTransportErr(arena, reply);

    const pid = reply.value.object.get("panel_id");
    const id: i64 = if (pid) |p| (if (p == .integer) p.integer else 0) else 0;

    var res = Res.init(arena);
    try res.fact("panel_id", id);
    try res.fact("name", panel_name);
    try res.fact("session", session);
    try res.fact("target", target);
    try res.fact("showing", true);
    try res.textf("showing panel {s} (id {d}) in session {s} as {s}", .{
        panel_name, id, panelstore.sessionLabel(session), target,
    });
    try addUiAssetFacts(&res, arena, reply);
    return res.finish();
}

// A document GENERATOR over the exact path ui_show uses: it builds
// the document server-side and hands it to the same panel-show.
// There is no second rendering path, no new component and no new
// control command here, deliberately.
fn uiShowFiles(arena: std.mem.Allocator, args: std.json.Value, transport: *UiTransport, session: ?[]const u8) ![]const u8 {
    const files_v = if (args == .object) args.object.get("files") else null;
    const items = blk: {
        const v = files_v orelse
            return errRes(arena, .invalid_args, "ui_show_files requires 'files': a list of absolute image paths, or {path, caption} objects");
        if (v != .array or v.array.items.len == 0)
            return errRes(arena, .invalid_args, "'files' must be a NON-EMPTY array of absolute image paths (or {path, caption} objects)");
        break :blk v.array.items;
    };
    if (items.len > UI_FILES_MAX) {
        const msg = std.fmt.allocPrint(
            arena,
            "ui_show_files shows at most {d} files at once and got {d} — show a subset (the user can be sent the next batch by re-calling with the same 'name'), or author a paged panel with ui_show.",
            .{ UI_FILES_MAX, items.len },
        ) catch return error.OutOfMemory;
        return errRes(arena, .invalid_args, msg);
    }
    const compare = argBool(args, "compare");
    if (compare and items.len != 2) {
        const msg = std.fmt.allocPrint(
            arena,
            "compare:true draws ONE A/B slider between exactly two images, and 'files' has {d}. Pass exactly two files, or drop 'compare' to stack them as separate images.",
            .{items.len},
        ) catch return error.OutOfMemory;
        return errRes(arena, .invalid_args, msg);
    }

    const files = arena.alloc(UiFile, items.len) catch return error.OutOfMemory;
    var unreadable: std.ArrayList([]const u8) = .empty;
    for (items, 0..) |item, i| {
        const path: []const u8 = switch (item) {
            .string => |s| s,
            .object => |o| pblk: {
                const pv = o.get("path") orelse {
                    const msg = std.fmt.allocPrint(arena, "files[{d}] has no \"path\"", .{i}) catch
                        return error.OutOfMemory;
                    return errRes(arena, .invalid_args, msg);
                };
                if (pv != .string) {
                    const msg = std.fmt.allocPrint(arena, "files[{d}].path must be a string", .{i}) catch
                        return error.OutOfMemory;
                    return errRes(arena, .invalid_args, msg);
                }
                break :pblk pv.string;
            },
            else => {
                const msg = std.fmt.allocPrint(
                    arena,
                    "files[{d}] must be an absolute path string or a {{path, caption}} object",
                    .{i},
                ) catch return error.OutOfMemory;
                return errRes(arena, .invalid_args, msg);
            },
        };
        if (!paneldoc.validImagePath(path)) {
            const msg = std.fmt.allocPrint(
                arena,
                "files[{d}]: \"{s}\" must be an ABSOLUTE path with no \"..\" segment and no control characters (panels are persisted and re-opened later, so paths are constrained structurally)",
                .{ i, path },
            ) catch return error.OutOfMemory;
            return errRes(arena, .invalid_args, msg);
        }
        var caption: []const u8 = std.fs.path.basename(path);
        if (item == .object) {
            if (item.object.get("caption")) |cv| {
                if (cv != .string) {
                    const msg = std.fmt.allocPrint(arena, "files[{d}].caption must be a string", .{i}) catch
                        return error.OutOfMemory;
                    return errRes(arena, .invalid_args, msg);
                }
                caption = cv.string;
            }
        }
        if (caption.len > paneldoc.MAX_TEXT) {
            const msg = std.fmt.allocPrint(
                arena,
                "files[{d}].caption is longer than {d} characters",
                .{ i, paneldoc.MAX_TEXT },
            ) catch return error.OutOfMemory;
            return errRes(arena, .invalid_args, msg);
        }
        files[i] = .{ .path = path, .caption = caption };

        // Readability is checked HERE rather than left to the
        // renderer's placeholder: a placeholder is right for the
        // one image that vanished mid-training, but a panel made
        // entirely of them is a typo the assistant must be told
        // about, not shown to the user.
        const z = std.fmt.allocPrintSentinel(arena, "{s}", .{path}, 0) catch
            return error.OutOfMemory;
        if (c.access(z.ptr, c.R_OK) != 0)
            unreadable.append(arena, path) catch return error.OutOfMemory;
    }

    if (unreadable.items.len == items.len) {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.print(
            "none of the {d} file(s) can be read, so nothing was shown (a panel of nothing but placeholders would only look broken). Check the paths:",
            .{items.len},
        );
        for (unreadable.items, 0..) |p, i| {
            if (i >= 5) {
                try w.print(" … and {d} more", .{unreadable.items.len - i});
                break;
            }
            try w.print(" {s}", .{p});
        }
        return errRes(arena, .invalid_args, aw.written());
    }

    const title = argStr(args, "title") orelse "";
    const document = uiFilesDocument(arena, files, title, compare) catch
        return error.OutOfMemory;
    // The generator's own output is validated before it leaves:
    // an invalid document must never reach the GUI as an opaque
    // rejection of something the assistant did not write.
    var gen_diag = paneldoc.Diag{};
    var checked = paneldoc.Document.parse(arena, document, &gen_diag) catch |err| {
        const msg = std.fmt.allocPrint(
            arena,
            "ui_show_files built a document its own parser rejected ({s}: {s}) — that is a sketerm bug; ui_show with a hand-written document still works",
            .{ @errorName(err), gen_diag.msg() },
        ) catch return error.OutOfMemory;
        return errRes(arena, .invalid_args, msg);
    };
    checked.deinit();

    const panel_name = argStr(args, "name") orelse UI_FILES_NAME;
    const target = argStr(args, "target") orelse "tab";
    const reply = uiTalk(transport, .{
        .cmd = "panel-show",
        .name = panel_name,
        .session = uiWireSession(session),
        .target = target,
        .document = document,
    });
    if (!reply.ok) return uiTransportErr(arena, reply);
    const pid = reply.value.object.get("panel_id");
    const id: i64 = if (pid) |p| (if (p == .integer) p.integer else 0) else 0;

    const layout: []const u8 = if (compare) "image_compare" else "stacked_images";
    var res = Res.init(arena);
    try res.fact("panel_id", id);
    try res.fact("name", panel_name);
    try res.fact("session", session);
    try res.fact("target", target);
    try res.fact("files", files.len);
    try res.fact("layout", layout);
    try res.fact("showing", true);
    try res.textf("showing {d} image(s) as {s} in panel {s} (id {d})", .{
        files.len, layout, panel_name, id,
    });
    if (unreadable.items.len > 0) {
        try res.fact("unreadable", unreadable.items);
        try res.textf(
            "{d} of {d} file(s) could not be read; they are drawn as an explicit placeholder in the panel, the rest render normally",
            .{ unreadable.items.len, files.len },
        );
    }
    try addUiAssetFacts(&res, arena, reply);
    return res.finish();
}

fn uiPatch(arena: std.mem.Allocator, args: std.json.Value, transport: *UiTransport, session: ?[]const u8) ![]const u8 {
    const patch = (try uiJsonArg(arena, args, "patch")) orelse
        return errRes(arena, .invalid_args, "ui_patch requires 'patch' (a JSON array of ops)");
    const target = uiResolve(arena, transport, args, session);
    if (target.err.len > 0) return uiResolveErr(arena, target);
    const reply = uiTalk(transport, .{
        .cmd = "panel-patch",
        .panel_id = target.id,
        .patch = patch,
        .session = uiWireSession(session),
    });
    if (!reply.ok) return uiTransportErr(arena, reply);
    var res = Res.init(arena);
    try res.fact("panel_id", target.id);
    try res.fact("patched", true);
    try res.textf("patched panel {d}", .{target.id});
    try addUiAssetFacts(&res, arena, reply);
    return res.finish();
}

/// How ui_wait_event reads a panel's queue.
const EventRead = enum {
    /// `panel-events-reliable`: peek, and acknowledge only what an
    /// earlier reply already delivered.
    reliable,
    /// `panel-events`: the destructive drain, for a GUI older than the
    /// reliable read.
    drain,
};

/// Reliable-read bookkeeping for one live panel: what this server has
/// already handed a caller (acknowledged by the NEXT poll, so a reply
/// lost on the way back is re-read rather than lost), the panel
/// lifetime that belongs to, and whether its GUI predates the read.
const EventCursor = struct {
    epoch: ?panelrpc.EventEpoch = null,
    acked: u64 = 0,
    /// The queue's cumulative `dropped_total` last reported, so a result
    /// states the drops that are NEW to its caller.
    dropped_seen: u64 = 0,
    read: EventRead = .reliable,
};

/// Cursors keyed by (wire session, panel id). Process-lifetime state,
/// like the panel transport pool.
var event_cursors: std.StringHashMapUnmanaged(EventCursor) = .empty;
const cursor_allocator = std.heap.c_allocator;

fn cursorKey(buf: []u8, session: ?[]const u8, panel_id: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}\x00{s}", .{ panel_id, uiWireSession(session) }) catch buf[0..0];
}

fn storeCursor(key: []const u8, cursor: EventCursor) void {
    if (key.len == 0) return;
    if (event_cursors.getPtr(key)) |slot| {
        slot.* = cursor;
        return;
    }
    const owned = cursor_allocator.dupe(u8, key) catch return;
    event_cursors.put(cursor_allocator, owned, cursor) catch cursor_allocator.free(owned);
}

/// Forget every panel's reliable-read cursor (test isolation).
fn resetEventCursors() void {
    var it = event_cursors.keyIterator();
    while (it.next()) |k| cursor_allocator.free(k.*);
    event_cursors.deinit(cursor_allocator);
    event_cursors = .empty;
}

/// A GUI that predates `panel-events-reliable` answers it as an unknown
/// command: by code, or by prose from a GUI older than codes too.
fn reliableUnsupported(reply: IpcReply) bool {
    if (reply.delivery != .ordinary) return false;
    if (reply.code) |code| return code == .unknown_command;
    return std.mem.indexOf(u8, reply.err, "unknown panel command") != null or
        std.mem.indexOf(u8, reply.err, "unknown command") != null;
}

fn uiWaitEvent(arena: std.mem.Allocator, args: std.json.Value, transport: *UiTransport, session: ?[]const u8) ![]const u8 {
    const backend = transport.backend;
    const asked: i64 = argInt(args, "timeout_ms") orelse UI_WAIT_DEFAULT_MS;
    const timeout_ms = @min(@max(asked, 0), WAIT_CAP_MS);
    // One budget includes name resolution, every poll round trip, and
    // sleeps. A slow presenter cannot multiply timeout_ms by poll count.
    const start = backend.nowMs(backend.ctx);
    const deadline = start + timeout_ms;
    const target = uiResolveFor(arena, transport, args, session, deadline - backend.nowMs(backend.ctx));
    if (target.err.len > 0) return uiResolveErr(arena, target);

    var key_buf: [128]u8 = undefined;
    const key = cursorKey(&key_buf, session, target.id);
    var cur: EventCursor = event_cursors.get(key) orelse .{};
    defer storeCursor(key, cur);

    // The GUI answers immediately (it runs on the main loop and must
    // never block), so the WAIT is ours: poll until something is queued
    // or the budget runs out.
    var dropped_new: i64 = 0;
    while (true) {
        const before_poll = backend.nowMs(backend.ctx);
        const remain = deadline - before_poll;
        if (remain <= 0)
            return uiEventsResult(arena, target.id, before_poll - start, null, dropped_new, timeout_ms, cur.read);
        const reply = switch (cur.read) {
            .reliable => transport.talkFor(.{
                .cmd = "panel-events-reliable",
                .panel_id = target.id,
                .session = uiWireSession(session),
                .ack = cur.acked,
                .event_epoch = if (cur.epoch) |*epoch| epoch else null,
            }, remain),
            .drain => transport.talkFor(.{
                .cmd = "panel-events",
                .panel_id = target.id,
                .session = uiWireSession(session),
            }, remain),
        };
        if (!reply.ok) {
            if (cur.read == .reliable and reliableUnsupported(reply)) {
                cur.read = .drain;
                continue;
            }
            if (cur.read == .reliable and reply.delivery == .ordinary and reply.code == .event_epoch_mismatch) {
                // Same id, new panel lifetime: nothing of the old one is
                // pending any more, so start that lifetime from nothing.
                cur = .{};
                continue;
            }
            return uiWaitFailure(arena, reply, cur.read);
        }
        var events: ?std.json.Value = reply.value.object.get("events");
        switch (cur.read) {
            .reliable => {
                const epoch = objStr(reply.value, "event_epoch");
                if (!panelrpc.validEventEpoch(epoch))
                    return errRes(arena, .io_failed, "the GUI answered panel-events-reliable without a valid event_epoch");
                if (cur.epoch == null or !std.mem.eql(u8, &cur.epoch.?, epoch)) {
                    // A new lifetime (or the first poll): its sequence space starts over.
                    var fresh: panelrpc.EventEpoch = undefined;
                    @memcpy(&fresh, epoch);
                    cur = .{ .epoch = fresh };
                }
                const cursor = objInt(reply.value, "cursor");
                const dropped_total = objInt(reply.value, "dropped_total");
                if (dropped_total > @as(i64, @intCast(cur.dropped_seen))) {
                    dropped_new += dropped_total - @as(i64, @intCast(cur.dropped_seen));
                }
                cur.dropped_seen = @intCast(@max(dropped_total, 0));
                // Handed to the caller now, acknowledged by the next poll.
                cur.acked = @intCast(@max(cursor, 0));
            },
            .drain => {
                if (reply.value.object.get("dropped")) |d| {
                    if (d == .integer) dropped_new += d.integer;
                }
            },
        }
        const count: usize = if (events) |e| (if (e == .array) e.array.items.len else 0) else 0;
        if (count == 0) events = null;
        const elapsed = backend.nowMs(backend.ctx) - start;
        if (count > 0 or elapsed >= timeout_ms)
            return uiEventsResult(arena, target.id, elapsed, events, dropped_new, timeout_ms, cur.read);
        const sleep_remain = deadline - backend.nowMs(backend.ctx);
        if (sleep_remain > 0)
            backend.sleepMs(backend.ctx, @intCast(@min(@as(i64, UI_POLL_MS), sleep_remain)));
    }
}

/// A failed poll, told the way its read makes true: only the destructive
/// drain can have consumed interactions whose reply was then lost.
fn uiWaitFailure(arena: std.mem.Allocator, reply: IpcReply, read: EventRead) ![]const u8 {
    switch (reply.delivery) {
        .uncertain_delivery => return errRes(arena, .io_failed, switch (read) {
            .drain => try std.fmt.allocPrint(
                arena,
                "the panel-events request may have drained queued interactions before its reply was lost ({s}). Events may have been drained; failure_class=uncertain_delivery, events_may_have_been_drained=true, resend_safe=false. The poll was NOT retried automatically",
                .{reply.err},
            ),
            .reliable => try std.fmt.allocPrint(
                arena,
                "the panel event reply was lost ({s}); nothing was consumed: the reliable read acknowledges only what an earlier reply delivered, so calling ui_wait_event again re-reads every pending interaction. failure_class=uncertain_delivery, events_may_have_been_drained=false, resend_safe=true",
                .{reply.err},
            ),
        }),
        .pre_delivery => return errRes(arena, .unavailable, try std.fmt.allocPrint(
            arena,
            "the panel event poll was unavailable before presenter delivery ({s}); failure_class=pre_delivery, events_may_have_been_drained=false, resend_safe=true. The panel's open/closed state and queued events are UNKNOWN; retry when a compatible GUI is attached",
            .{reply.err},
        )),
        .ordinary => return errRes(arena, .not_found, try std.fmt.allocPrint(
            arena,
            "the GUI presenter confirmed that this panel is not live ({s}); it may have been closed by the user or the id may never have existed",
            .{reply.err},
        )),
    }
}

fn uiPanels(arena: std.mem.Allocator, _: std.json.Value, transport: *UiTransport, session: ?[]const u8) ![]const u8 {
    var res = Res.init(arena);
    try res.fact("session", session);
    var text: std.Io.Writer.Allocating = .init(arena);
    const tw = &text.writer;

    const reply = uiTalk(transport, .{ .cmd = "panel-list", .session = uiWireSession(session) });
    if (!reply.ok) {
        try res.raw("live", "null");
        try res.fact("live_error", reply.err);
        try res.textf("live: unavailable ({s})", .{reply.err});
    } else {
        const panels = reply.value.object.get("panels");
        const items: []const std.json.Value =
            if (panels != null and panels.? == .array) panels.?.array.items else &.{};
        var aw: std.Io.Writer.Allocating = .init(arena);
        if (panels != null and panels.? == .array)
            try std.json.Stringify.value(panels.?, .{}, &aw.writer)
        else
            try aw.writer.writeAll("[]");
        try res.raw("live", aw.written());
        try res.fact("live_count", items.len);
        try res.textf("live: {d} panel(s)", .{items.len});
        for (items) |p| {
            try tw.print("\nlive {d} {s}", .{ objInt(p, "panel_id"), objStr(p, "name") });
            const title = objStr(p, "title");
            if (title.len > 0) try tw.print("  {s}", .{title});
        }
    }

    const store = uiStoreScope(transport, UI_RELAY_CALL_MS);
    if (store.err.len > 0) {
        try res.raw("saved", "null");
        try res.fact("saved_error", store.err);
        try res.textf("saved: unavailable ({s})", .{store.err});
    } else if (panelstore.listScoped(arena, store.scope)) |entries| {
        var aw: std.Io.Writer.Allocating = .init(arena);
        const w = &aw.writer;
        try w.writeAll("[");
        for (entries, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            try w.writeAll("{\"name\":");
            try std.json.Stringify.value(e.name, .{}, w);
            try w.writeAll(",\"title\":");
            try std.json.Stringify.value(e.title, .{}, w);
            try w.print(",\"bytes\":{d},\"mtime\":{d},\"parses\":{}}}", .{ e.bytes, e.mtime, e.ok });
            try tw.print("\nsaved {s}  {d} bytes", .{ e.name, e.bytes });
            if (e.title.len > 0) try tw.print("  {s}", .{e.title});
            if (!e.ok) try tw.writeAll("  (does NOT parse)");
        }
        try w.writeAll("]");
        try res.raw("saved", aw.written());
        try res.fact("saved_count", entries.len);
        try res.textf("saved: {d} document(s)", .{entries.len});
    } else |err| {
        try res.raw("saved", "null");
        try res.fact("saved_error", @errorName(err));
        try res.textf("saved: unavailable ({s})", .{@errorName(err)});
    }
    if (text.written().len > 0) try res.textf("--- panels ---{s}", .{text.written()});
    return res.finish();
}

fn uiSave(arena: std.mem.Allocator, args: std.json.Value, transport: *UiTransport, session: ?[]const u8) ![]const u8 {
    const panel_name = argStr(args, "name") orelse
        return errRes(arena, .invalid_args, "ui_save requires 'name' (what to save it as)");
    var diag = paneldoc.Diag{};
    // No document: read the LIVE one back from the GUI. That works
    // for ANY panel on screen — including one another process
    // showed — because the GUI's registry is the only copy.
    const document = (try uiJsonArg(arena, args, "document")) orelse blk: {
        if (transport.mode == .none) return errRes(arena, .unavailable, UI_SAVE_NEEDS_TRANSPORT);
        const target = uiResolve(arena, transport, args, session);
        if (target.err.len > 0) return uiResolveErr(arena, target);
        const live = uiLiveDocument(transport, target.id, session);
        if (live.err.len > 0) return errRes(arena, .unavailable, live.err);
        break :blk live.json;
    };
    const store = uiStoreScope(transport, UI_RELAY_CALL_MS);
    if (store.err.len > 0) return errRes(arena, .unavailable, store.err);
    const canonical_bytes = panelstore.saveJsonScoped(arena, store.scope, panel_name, document, &diag) catch |err|
        return uiStoreMutationErr(arena, err, &diag, "ui_save refused to store the panel", "save");
    var res = Res.init(arena);
    try res.fact("saved", panel_name);
    try res.fact("session", session);
    try res.fact("bytes", canonical_bytes);
    try res.textf("saved {s} in session {s}: {d} canonical bytes on disk", .{
        panel_name, panelstore.sessionLabel(session), canonical_bytes,
    });
    return res.finish();
}

fn uiClose(arena: std.mem.Allocator, args: std.json.Value, transport: *UiTransport, session: ?[]const u8) ![]const u8 {
    const target = uiResolve(arena, transport, args, session);
    if (target.err.len > 0) return uiResolveErr(arena, target);
    const reply = uiTalk(transport, .{
        .cmd = "panel-close",
        .panel_id = target.id,
        .session = uiWireSession(session),
    });
    if (!reply.ok) return uiTransportErr(arena, reply);
    var res = Res.init(arena);
    try res.fact("panel_id", target.id);
    try res.fact("closed", true);
    try res.textf("closed panel {d}", .{target.id});
    return res.finish();
}

fn uiDelete(arena: std.mem.Allocator, args: std.json.Value, transport: *UiTransport, session: ?[]const u8) ![]const u8 {
    const panel_name = argStr(args, "name") orelse
        return errRes(arena, .invalid_args, "ui_delete requires 'name' (the SAVED panel to delete)");
    var diag = paneldoc.Diag{};
    const store = uiStoreScope(transport, UI_RELAY_CALL_MS);
    if (store.err.len > 0) return errRes(arena, .unavailable, store.err);
    panelstore.deleteScoped(arena, store.scope, panel_name, &diag) catch |err|
        return uiStoreMutationErr(arena, err, &diag, "ui_delete could not delete the saved panel", "delete");
    var res = Res.init(arena);
    try res.fact("deleted", panel_name);
    try res.fact("session", session);
    try res.textf("deleted the saved document {s} in session {s}", .{
        panel_name, panelstore.sessionLabel(session),
    });
    return res.finish();
}

const DirectDropScript = struct {
    const Mode = enum { after_prefix, after_line };

    listener: c_int,
    mode: Mode,

    fn run(self: DirectDropScript) void {
        const accepted = c.accept(self.listener, null, null);
        if (accepted < 0) return;
        defer _ = c.close(accepted);
        var buf: [16 << 10]u8 = undefined;
        switch (self.mode) {
            .after_prefix => {
                _ = c.read(accepted, &buf, buf.len);
            },
            .after_line => while (true) {
                const n = c.read(accepted, &buf, buf.len);
                if (n <= 0) return;
                if (std.mem.indexOfScalar(u8, buf[0..@intCast(n)], '\n') != null) return;
            },
        }
    }
};

const LegacyPanelDaemonScript = struct {
    listener: c_int,
    delay_us: u32,

    fn run(self: LegacyPanelDaemonScript) void {
        const accepted = c.accept(self.listener, null, null);
        if (accepted < 0) return;
        var conn = muxclient.Conn{ .allocator = std.heap.c_allocator, .fd = accepted };
        defer conn.deinit();
        const hello = conn.recvExpect(&.{.hello}) catch return;
        hello.deinit(conn.allocator);
        _ = c.usleep(self.delay_us);
        // Exact pre-panel daemon: normal mux negotiation, no panel_rpc.
        conn.sendFrame(.welcome, "{\"proto\":6,\"server_proto\":6,\"negotiation\":1}") catch return;
    }
};

fn directDropListener(path: [:0]const u8) !c_int {
    const listener = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
    if (listener < 0) return error.SocketFailed;
    errdefer _ = c.close(listener);
    var addr: c.struct_sockaddr_un = undefined;
    try @import("../mux/daemon.zig").fillSockaddrUn(&addr, path);
    if (c.bind(listener, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0)
        return error.BindFailed;
    if (c.listen(listener, 1) != 0) return error.ListenFailed;
    return listener;
}

/// Every environment variable that can steer a ui_* call away from the
/// injected `FakeBackend`. `SKETERM_MUX_SOCKET` is the load-bearing one:
/// `UiTransport.init` treats a session plus an environment socket as an
/// EXACT origin and takes the mux relay, so a suite run from inside a
/// live sketerm pane would talk to the developer's real daemon instead
/// of the fake, and the ui_* tests would fail on that machine only.
const UI_ISOLATED_ENV = [_][*:0]const u8{
    "SKETERM_SESSION",
    "SKETERM_MUX_SOCKET",
    "SKETERM_SESSION_ORIGIN_ID",
};

/// XDG_STATE_HOME pointed at a scratch dir, plus a GUI socket the
/// ui_* tools will believe in. Every panelstore path derives from the
/// state dir, so without this the tests would write into the
/// developer's real panel store.
const UiScratch = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    saved_gui: bool = false,
    saved_source: GuiSocketSource = .none,
    saved_state_home: EnvSave = .{},
    saved_env: [UI_ISOLATED_ENV.len]EnvSave = @splat(.{}),

    fn init(self: *UiScratch, tag: []const u8, gui: bool) !void {
        self.* = .{};
        resetEventCursors();
        try self.saved_state_home.take("XDG_STATE_HOME");
        for (&self.saved_env, UI_ISOLATED_ENV) |*slot, name| try slot.take(name);
        const p = try std.fmt.bufPrintZ(&self.buf, "/tmp/sketerm-mcp-ui-{s}-{d}", .{ tag, c.getpid() });
        self.len = p.len;
        _ = c.mkdir(@ptrCast(&self.buf), 0o755);
        _ = c.setenv("XDG_STATE_HOME", @ptrCast(&self.buf), 1);
        self.saved_gui = mcp.srv_gui_socket;
        self.saved_source = mcp.srv_gui_socket_source;
        mcp.srv_gui_socket = gui;
        mcp.srv_gui_socket_source = if (gui) .explicit else .none;
    }

    fn deinit(self: *UiScratch) void {
        resetEventCursors();
        mcp.srv_gui_socket = self.saved_gui;
        mcp.srv_gui_socket_source = self.saved_source;
        var i = self.saved_env.len;
        while (i > 0) {
            i -= 1;
            self.saved_env[i].restore();
        }
        self.saved_state_home.restore();
        var cmd: [256]u8 = undefined;
        const z = std.fmt.bufPrintZ(&cmd, "rm -rf {s}", .{self.buf[0..self.len]}) catch return;
        _ = c.system(z.ptr);
        self.* = undefined;
    }
};

const UI_DOC =
    \\{"title":"Epoch 41","root":"ok","components":{"ok":{"type":"button","text":"Approve","action":"approve"}}}
;

test "ui_show sends the document to the GUI, and ui_save reads the live one back" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("show", true);
    defer scratch.deinit();

    const LIVE_DOC =
        \\{"title":"Epoch 42","root":"ok","components":{"ok":{"type":"button","text":"Approve","action":"approve"}}}
    ;
    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":true,\"panel_id\":7,\"session\":\"s1\"}", // panel-show
            "{\"ok\":true,\"panels\":[{\"panel_id\":7,\"name\":\"train\",\"session\":\"s1\",\"title\":\"Epoch 41\",\"target\":\"tab\"}]}", // panel-list (name -> id)
            "{\"ok\":true}", // panel-patch
            "{\"ok\":true,\"panels\":[{\"panel_id\":7,\"name\":\"train\",\"session\":\"s1\",\"title\":\"Epoch 42\",\"target\":\"tab\"}]}", // panel-list (name -> id)
            "{\"ok\":true,\"document\":\"{\\\"title\\\":\\\"Epoch 42\\\",\\\"root\\\":\\\"ok\\\",\\\"components\\\":{\\\"ok\\\":{\\\"type\\\":\\\"button\\\",\\\"text\\\":\\\"Approve\\\",\\\"action\\\":\\\"approve\\\"}}}\",\"name\":\"train\",\"session\":\"s1\",\"title\":\"Epoch 42\"}", // panel-get
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_show","arguments":{"name":"train","session":"s1","document":{"title":"Epoch 41","root":"ok","components":{"ok":{"type":"button","text":"Approve","action":"approve"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_show", try rpcToolResult(arena, resp));
        const sc = shape.object.get("structuredContent").?.object;
        try std.testing.expectEqual(@as(i64, 7), sc.get("panel_id").?.integer);
        try std.testing.expectEqualStrings("train", sc.get("name").?.string);
        try std.testing.expect(sc.get("showing").?.bool);
    }
    // The document travelled as the control socket's JSON string, and
    // the target defaulted to a tab.
    const req = fake.requests.items[0];
    try std.testing.expect(std.mem.indexOf(u8, req, "\"cmd\":\"panel-show\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"target\":\"tab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "\"session\":\"s1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "image_compare") == null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Approve") != null);

    // A patch by name resolves the id and forwards the ops — and does
    // NOT keep any document state on this side.
    const patched = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_patch","arguments":{"name":"train","session":"s1","patch":[{"op":"title","value":"Epoch 42"}]}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, patched, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_patch", try rpcToolResult(arena, patched));
        try std.testing.expect(shape.object.get("structuredContent").?.object.get("patched").?.bool);
    }
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[2], "\"cmd\":\"panel-patch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[2], "\"panel_id\":7") != null);
    // Exactly one list + one patch: no extra round-trip to learn a name.
    try std.testing.expectEqual(@as(usize, 3), fake.requests.items.len);

    // ui_save with no document reads the panel back over panel-get and
    // stores THAT — the patched title included, because the GUI is the
    // one holding the document.
    const saved = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"train","session":"s1"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, saved, "isError") == null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[4], "\"cmd\":\"panel-get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[4], "\"panel_id\":7") != null);
    try std.testing.expect(panelstore.existsScoped(arena, .{ .session = "s1" }, "train"));
    var loaded = try panelstore.loadScoped(arena, .{ .session = "s1" }, "train", null);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("Epoch 42", loaded.title);

    // The stored bytes are exactly what the GUI reported, canonically
    // serialized — not a re-derivation of anything held here.
    var live = try paneldoc.Document.parse(arena, LIVE_DOC, null);
    defer live.deinit();
    const want = try live.toJson(arena);
    const on_disk = try panelstore.loadJsonScoped(arena, .{ .session = "s1" }, "train", null);
    try std.testing.expectEqualStrings(want, on_disk);
}

test "ui_save persists a panel this server never showed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("foreign", true);
    defer scratch.deinit();

    // Nothing was ever shown through THIS server: the panel belongs to
    // another process (or to a run before this one). The mirror this
    // path replaced could not save it at all.
    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":true,\"panels\":[{\"panel_id\":3,\"name\":\"theirs\",\"session\":\"s9\",\"title\":\"Theirs\",\"target\":\"window\"}]}", // panel-list
            "{\"ok\":true,\"document\":\"{\\\"title\\\":\\\"Theirs\\\",\\\"root\\\":\\\"t\\\",\\\"components\\\":{\\\"t\\\":{\\\"type\\\":\\\"text\\\",\\\"text\\\":\\\"hi\\\"}}}\",\"name\":\"theirs\",\"session\":\"s9\",\"title\":\"Theirs\"}", // panel-get
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const saved = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"theirs","session":"s9"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, saved, "isError") == null);
    var loaded = try panelstore.loadScoped(arena, .{ .session = "s9" }, "theirs", null);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("Theirs", loaded.title);

    // A panel that is not on screen is a described refusal naming the
    // session, not a save of something stale.
    var fake2 = FakeBackend{
        .responses = &.{"{\"ok\":true,\"panels\":[]}"},
        .allocator = std.testing.allocator,
    };
    defer fake2.deinit();
    const missing = handleMessage(arena, fake2.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"ghost","session":"s9"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, missing, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, missing, "ghost") != null);
}

test "ui_save reports the canonical byte count actually stored" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("canonical-bytes", false);
    defer scratch.deinit();
    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();

    const authored =
        \\  {
        \\    "components": { "t": { "text": "saved", "type": "text" } },
        \\    "root": "t",
        \\    "title": "Canonical"
        \\  }
    ;
    var request: std.Io.Writer.Allocating = .init(arena);
    try request.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"ui_save\",\"arguments\":{\"name\":\"canonical\",\"session\":\"\",\"document\":");
    try std.json.Stringify.value(authored, .{}, &request.writer);
    try request.writer.writeAll("}}}");
    const response = handleMessage(arena, fake.backend(), request.written()).?;
    try t.expect(std.mem.indexOf(u8, response, "isError") == null);

    const stored = try panelstore.loadJsonScoped(arena, .sessionless, "canonical", null);
    try t.expect(stored.len < authored.len);
    const shape = try expectToolResultShape(arena, "ui_save", try rpcToolResult(arena, response));
    try t.expectEqual(@as(i64, @intCast(stored.len)), shape.object.get("structuredContent").?.object.get("bytes").?.integer);
}

test "ui_save without a document needs a live panel transport" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("savenogui", false);
    defer scratch.deinit();

    var fake = FakeBackend{ .responses = &.{}, .allocator = std.testing.allocator };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"p","session":"s1"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "live panel transport") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "'document'") != null);
    // Nothing was attempted on the socket, and nothing was written.
    try std.testing.expectEqual(@as(usize, 0), fake.requests.items.len);
    try std.testing.expect(!panelstore.existsScoped(arena, .{ .session = "s1" }, "p"));
}

test "an explicit empty ui session overrides SKETERM_SESSION for live and saved panels" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("explicit-empty", true);
    defer scratch.deinit();
    _ = c.setenv("SKETERM_SESSION", "environment-session", 1);
    defer _ = c.unsetenv("SKETERM_SESSION");

    var fake = FakeBackend{
        .responses = &.{"{\"ok\":true,\"panel_id\":17}"},
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();
    const shown = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_show","arguments":{"name":"sessionless","session":"","document":{"root":"t","components":{"t":{"type":"text","text":"x"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, shown, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_show", try rpcToolResult(arena, shown));
        try std.testing.expectEqual(std.json.Value{ .null = {} }, shape.object.get("structuredContent").?.object.get("session").?);
    }
    try std.testing.expectEqual(@as(usize, 1), fake.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"session\":\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "environment-session") == null);

    const saved = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"sessionless","session":"","document":{"root":"t","components":{"t":{"type":"text","text":"saved"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, saved, "isError") == null);
    try std.testing.expect(panelstore.existsScoped(arena, .sessionless, "sessionless"));
    try std.testing.expect(!panelstore.existsScoped(arena, .{ .session = "environment-session" }, "sessionless"));
}

test "every ui tool rejects a present non-string session without fallback or side effects" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("session-types", false);
    defer scratch.deinit();
    _ = c.setenv("SKETERM_SESSION", "environment-session", 1);
    defer _ = c.unsetenv("SKETERM_SESSION");

    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    const tools = [_][]const u8{
        "ui_show",   "ui_show_files", "ui_patch", "ui_wait_event",
        "ui_panels", "ui_save",       "ui_close", "ui_delete",
    };
    const invalid = [_][]const u8{ "null", "0", "1.5", "{}", "[]", "true", "false" };
    var id: usize = 1;
    for (tools) |tool| {
        for (invalid) |value| {
            const request = try std.fmt.allocPrint(
                arena,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{\"session\":{s}}}}}}}",
                .{ id, tool, value },
            );
            id += 1;
            const response = handleMessage(arena, fake.backend(), request).?;
            try t.expect(std.mem.indexOf(u8, response, "isError") != null);
            try t.expect(std.mem.indexOf(u8, response, "must be a string when present") != null);
            try t.expect(std.mem.indexOf(u8, response, "environment-session") == null);
        }
    }
    try t.expectEqual(@as(usize, 0), fake.requests.items.len);
    try t.expect(!panelstore.existsScoped(arena, .{ .session = "environment-session" }, "ui-invalid"));

    const absent = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":100,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"inherited","document":{"root":"t","components":{"t":{"type":"text","text":"saved"}}}}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, absent, "isError") == null);
    try t.expect(panelstore.existsScoped(arena, .{ .session = "environment-session" }, "inherited"));
}

test "ui_show refuses a bad document with the parser's own message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("bad", true);
    defer scratch.deinit();

    // The GUI is the one that parses; its Diag message must reach the
    // assistant verbatim, component id and all.
    var fake = FakeBackend{
        .responses = &.{"{\"ok\":false,\"error\":\"component \\\"r\\\": unknown type \\\"webview\\\"\"}"},
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();
    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_show","arguments":{"name":"x","session":"s1","document":"{\"root\":\"r\",\"components\":{\"r\":{\"type\":\"webview\"}}}"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "webview") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "unknown type") != null);

    // document + load together is a caller error caught before any IPC.
    const both = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_show","arguments":{"name":"x","document":{},"load":"y"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, both, "not both") != null);
    try std.testing.expectEqual(@as(usize, 1), fake.requests.items.len);
}

test "ui presenter protocol shapes cannot fabricate panel success" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("bad-presenter-shape", true);
    defer scratch.deinit();

    var fake = FakeBackend{
        .responses = &.{
            "[]",
            "{}",
            "{\"ok\":\"yes\"}",
            "{\"ok\":true}",
            "{\"ok\":true,\"panel_id\":0}",
            "{\"ok\":false}",
            "{\"ok\":false,\"error\":\"presenter disconnected\",\"failure_class\":\"uncertain_delivery\",\"mutation_may_have_applied\":true,\"resend_safe\":false}",
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();
    for (0..7) |i| {
        const request = try std.fmt.allocPrint(
            arena,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"ui_show\",\"arguments\":{{\"name\":\"shape\",\"session\":\"s1\",\"document\":{{\"root\":\"t\",\"components\":{{\"t\":{{\"type\":\"text\",\"text\":\"x\"}}}}}}}}}}}}",
            .{i + 1},
        );
        const response = handleMessage(arena, fake.backend(), request).?;
        try std.testing.expect(std.mem.indexOf(u8, response, "isError") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "delivery is uncertain") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "NOT resent") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "showing") == null);
    }
}

/// Create an empty file so ui_show_files' readability check passes.
fn touchFile(dir: []const u8, name: []const u8) void {
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return;
    const f = c.fopen(p.ptr, "wb") orelse return;
    _ = c.fwrite("x", 1, 1, f);
    _ = c.fclose(f);
}

test "ui_show_files generates a document the panel parser accepts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Stacked: a heading (because a title was given) plus one image per
    // file, in order, captions attached.
    const stacked = try uiFilesDocument(arena, &.{
        .{ .path = "/tmp/e40.png", .caption = "epoch 40" },
        .{ .path = "/tmp/e41.png", .caption = "e41.png" },
    }, "Epoch 41", false);
    var doc = try paneldoc.Document.parse(arena, stacked, null);
    defer doc.deinit();
    try std.testing.expectEqualStrings("Epoch 41", doc.title);
    try std.testing.expectEqualStrings("main", doc.root);
    const main = doc.get("main").?;
    try std.testing.expectEqual(@as(usize, 3), main.props.column.children.len);
    try std.testing.expectEqualStrings("h", main.props.column.children[0]);
    try std.testing.expectEqual(paneldoc.Kind.heading, doc.kindOf("h").?);
    try std.testing.expectEqualStrings("/tmp/e40.png", doc.get("img1").?.props.image.src);
    try std.testing.expectEqualStrings("epoch 40", doc.get("img1").?.props.image.caption);
    try std.testing.expectEqualStrings("/tmp/e41.png", doc.get("img2").?.props.image.src);

    // No title: no heading, and the column is images only.
    const untitled = try uiFilesDocument(arena, &.{
        .{ .path = "/tmp/a.png", .caption = "a.png" },
    }, "", false);
    var doc2 = try paneldoc.Document.parse(arena, untitled, null);
    defer doc2.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc2.get("main").?.props.column.children.len);
    try std.testing.expect(doc2.get("h") == null);

    // Compare: ONE image_compare, each caption becoming a side label.
    const cmp = try uiFilesDocument(arena, &.{
        .{ .path = "/tmp/e40.png", .caption = "epoch 40" },
        .{ .path = "/tmp/e41.png", .caption = "epoch 41" },
    }, "E41 vs E40", true);
    var doc3 = try paneldoc.Document.parse(arena, cmp, null);
    defer doc3.deinit();
    try std.testing.expectEqual(paneldoc.Kind.image_compare, doc3.kindOf("cmp").?);
    const ic = doc3.get("cmp").?.props.image_compare;
    try std.testing.expectEqualStrings("/tmp/e40.png", ic.left.src);
    try std.testing.expectEqualStrings("epoch 40", ic.left.label);
    try std.testing.expectEqualStrings("/tmp/e41.png", ic.right.src);
    try std.testing.expectEqualStrings("epoch 41", ic.right.label);
    try std.testing.expect(doc3.get("img1") == null);

    // A caption with quotes/newlines cannot break the generated JSON.
    const nasty = try uiFilesDocument(arena, &.{
        .{ .path = "/tmp/x.png", .caption = "he said \"hi\"\nthen \\left" },
    }, "a \"quoted\" title", false);
    var doc4 = try paneldoc.Document.parse(arena, nasty, null);
    defer doc4.deinit();
    try std.testing.expectEqualStrings("he said \"hi\"\nthen \\left", doc4.get("img1").?.props.image.caption);

    // Full cap: still one valid document (heading + 64 images < MAX_CHILDREN).
    var many: [UI_FILES_MAX]UiFile = undefined;
    for (&many) |*f| f.* = .{ .path = "/tmp/e.png", .caption = "e" };
    const big = try uiFilesDocument(arena, &many, "All", false);
    var doc5 = try paneldoc.Document.parse(arena, big, null);
    defer doc5.deinit();
    try std.testing.expectEqual(@as(usize, UI_FILES_MAX + 1), doc5.get("main").?.props.column.children.len);
}

test "ui_show_files shows an image set in one call, through the ui_show path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("files", true);
    defer scratch.deinit();
    const dir = scratch.buf[0..scratch.len];
    touchFile(dir, "e40.png");
    touchFile(dir, "e41.png");

    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":true,\"panel_id\":9}", // compare
            "{\"ok\":true,\"panel_id\":9}", // stacked, one file missing
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    // compare:true with exactly two files -> the A/B slider, captions
    // as side labels.
    const req_cmp = try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"ui_show_files","arguments":{{"session":"s1","title":"E41 vs E40","compare":true,"files":[{{"path":"{s}/e40.png","caption":"epoch 40"}},{{"path":"{s}/e41.png","caption":"epoch 41"}}]}}}}}}
    , .{ dir, dir });
    const resp = handleMessage(arena, fake.backend(), req_cmp).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_show_files", try rpcToolResult(arena, resp));
        const sc = shape.object.get("structuredContent").?.object;
        try std.testing.expectEqual(@as(i64, 9), sc.get("panel_id").?.integer);
        try std.testing.expectEqualStrings("image_compare", sc.get("layout").?.string);
        try std.testing.expectEqual(@as(i64, 2), sc.get("files").?.integer);
    }
    // It went out over the SAME panel-show the hand-authored path uses,
    // under the default name, as an image_compare document.
    const sent = fake.requests.items[0];
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"cmd\":\"panel-show\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"name\":\"files\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"target\":\"tab\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "image_compare") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "epoch 40") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "epoch 41") != null);

    // Stacked, with one path that does not exist: the panel is still
    // shown (the renderer draws a placeholder) and the reply NAMES the
    // file, so the assistant can tell.
    const req_stack = try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{{"name":"ui_show_files","arguments":{{"session":"s1","name":"preview","files":["{s}/e40.png","{s}/ghost.png"]}}}}}}
    , .{ dir, dir });
    const resp2 = handleMessage(arena, fake.backend(), req_stack).?;
    try std.testing.expect(std.mem.indexOf(u8, resp2, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_show_files", try rpcToolResult(arena, resp2));
        const sc = shape.object.get("structuredContent").?.object;
        try std.testing.expectEqualStrings("stacked_images", sc.get("layout").?.string);
        const unreadable = sc.get("unreadable").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), unreadable.len);
        try std.testing.expect(std.mem.endsWith(u8, unreadable[0].string, "ghost.png"));
    }
    const sent2 = fake.requests.items[1];
    try std.testing.expect(std.mem.indexOf(u8, sent2, "\"name\":\"preview\"") != null);
    // Bare strings caption themselves with the basename, and no title
    // means no heading.
    try std.testing.expect(std.mem.indexOf(u8, sent2, "\\\"caption\\\":\\\"e40.png\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent2, "heading") == null);
    try std.testing.expectEqual(@as(usize, 2), fake.requests.items.len);
}

test "ui_show_files refuses bad arity, bad paths and an all-missing set" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("files-bad", true);
    defer scratch.deinit();
    const dir = scratch.buf[0..scratch.len];
    touchFile(dir, "a.png");

    var fake = FakeBackend{ .responses = &.{"{\"ok\":true,\"panel_id\":1}"}, .allocator = std.testing.allocator };
    defer fake.deinit();

    // compare with three files: refused, clearly, before any IPC.
    const arity = handleMessage(arena, fake.backend(), try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"ui_show_files","arguments":{{"compare":true,"files":["{s}/a.png","{s}/a.png","{s}/a.png"]}}}}}}
    , .{ dir, dir, dir })).?;
    try std.testing.expect(std.mem.indexOf(u8, arity, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, arity, "exactly two") != null);

    // compare with one file: same refusal.
    const one = handleMessage(arena, fake.backend(), try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{{"name":"ui_show_files","arguments":{{"compare":true,"files":["{s}/a.png"]}}}}}}
    , .{dir})).?;
    try std.testing.expect(std.mem.indexOf(u8, one, "exactly two") != null);

    // Empty list, a relative path and a traversing path.
    const empty = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_show_files","arguments":{"files":[]}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, empty, "NON-EMPTY") != null);
    const relative = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ui_show_files","arguments":{"files":["rel.png"]}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, relative, "ABSOLUTE") != null);
    const traverse = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ui_show_files","arguments":{"files":["/a/../etc/shadow"]}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, traverse, "isError") != null);

    // Nothing readable at all: refused rather than shown as a wall of
    // placeholders, and the message names the paths.
    const gone = handleMessage(arena, fake.backend(), try std.fmt.allocPrint(arena,
        \\{{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{{"name":"ui_show_files","arguments":{{"files":["{s}/gone1.png","{s}/gone2.png"]}}}}}}
    , .{ dir, dir })).?;
    try std.testing.expect(std.mem.indexOf(u8, gone, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone, "none of the 2 file(s) can be read") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone, "gone2.png") != null);

    // Over the cap.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(std.testing.allocator);
    try big.appendSlice(std.testing.allocator,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ui_show_files","arguments":{"files":[
    );
    for (0..UI_FILES_MAX + 1) |i| {
        if (i > 0) try big.append(std.testing.allocator, ',');
        try big.appendSlice(std.testing.allocator, "\"/tmp/x.png\"");
    }
    try big.appendSlice(std.testing.allocator, "]}}}");
    const capped = handleMessage(arena, fake.backend(), big.items).?;
    try std.testing.expect(std.mem.indexOf(u8, capped, "at most 64 files") != null);

    // Not one of those reached the GUI.
    try std.testing.expectEqual(@as(usize, 0), fake.requests.items.len);
}

test "panel transport precedence is exact origin, explicit GUI, then default compatibility" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    var pool = paneldrive.Pool.init(t.allocator);
    defer pool.deinit();

    const old_pool = mcp.panel_pool;
    const old_gui = mcp.srv_gui_socket;
    const old_source = mcp.srv_gui_socket_source;
    const old_socket = if (c.getenv("SKETERM_MUX_SOCKET")) |value|
        try t.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(value))))
    else
        null;
    defer {
        mcp.panel_pool = old_pool;
        mcp.srv_gui_socket = old_gui;
        mcp.srv_gui_socket_source = old_source;
        if (old_socket) |value| {
            const z = std.fmt.allocPrintSentinel(t.allocator, "{s}", .{value}, 0) catch @panic("restore env oom");
            defer t.allocator.free(z);
            _ = c.setenv("SKETERM_MUX_SOCKET", z.ptr, 1);
            t.allocator.free(value);
        } else _ = c.unsetenv("SKETERM_MUX_SOCKET");
    }
    mcp.panel_pool = &pool;
    mcp.srv_gui_socket = true;
    mcp.srv_gui_socket_source = .explicit;

    _ = c.setenv("SKETERM_MUX_SOCKET", "/tmp/exact.sock", 1);
    var exact = UiTransport.init(arena, fake.backend(), "same");
    defer exact.deinit();
    try t.expect(exact.mode == .auto);
    exact.origin = try paneldrive.Origin.resolve(arena, "same");
    try t.expectEqualStrings("SKETERM_MUX_SOCKET", exact.source());

    _ = c.unsetenv("SKETERM_MUX_SOCKET");
    var explicit = UiTransport.init(arena, fake.backend(), "same");
    defer explicit.deinit();
    try t.expect(explicit.mode == .gui_socket);
    try t.expectEqualStrings("gui_socket_explicit", explicit.source());
    switch (uiStoreScope(&explicit, UI_RELAY_CALL_MS).scope) {
        .session => |session| try t.expectEqualStrings("same", session),
        else => return error.TestUnexpectedResult,
    }

    mcp.srv_gui_socket_source = .discovered;
    var compat = UiTransport.init(arena, fake.backend(), "same");
    defer compat.deinit();
    try t.expect(compat.mode == .auto);
    compat.origin = try paneldrive.Origin.resolve(arena, "same");
    try t.expectEqualStrings("default_socket_connect_only", compat.source());

    var sessionless = UiTransport.init(arena, fake.backend(), null);
    defer sessionless.deinit();
    try t.expect(sessionless.mode == .gui_socket);
    try t.expectEqualStrings("gui_socket_discovered", sessionless.source());
    try t.expect(uiStoreScope(&sessionless, UI_RELAY_CALL_MS).scope == .sessionless);

    // Without an exact inherited daemon or a live default-daemon probe, a
    // legacy caller retains the historical by-session namespace.
    var unavailable = UiTransport.init(arena, fake.backend(), "legacy");
    defer unavailable.deinit();
    unavailable.mode = .none;
    switch (uiStoreScope(&unavailable, UI_RELAY_CALL_MS).scope) {
        .session => |session| try t.expectEqualStrings("legacy", session),
        else => return error.TestUnexpectedResult,
    }
}

test "a daemon with no lifetime id falls back to by-session storage" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-store-legacy-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try directDropListener(path);
    defer _ = c.close(listener);
    const server = try std.Thread.spawn(.{}, LegacyPanelDaemonScript.run, .{LegacyPanelDaemonScript{
        .listener = listener,
        .delay_us = 0,
    }});
    defer server.join();

    const old_pool = mcp.panel_pool;
    var pool = paneldrive.Pool.init(t.allocator);
    defer pool.deinit();
    mcp.panel_pool = &pool;
    defer mcp.panel_pool = old_pool;
    _ = c.setenv("SKETERM_MUX_SOCKET", path.ptr, 1);
    _ = c.setenv("SKETERM_SESSION", "old-session", 1);
    _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");
    defer _ = c.unsetenv("SKETERM_SESSION");

    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    var transport = UiTransport.init(arena_state.allocator(), fake.backend(), "old-session");
    defer transport.deinit();
    const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
    try t.expectEqualStrings("", store.err);
    switch (store.scope) {
        .session => |session| try t.expectEqualStrings("old-session", session),
        else => return error.TestUnexpectedResult,
    }
    try t.expect(transport.failure == null);
}

test "exact persistence failures never select reusable legacy storage" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = c.setenv("SKETERM_MUX_SOCKET", "/tmp/exact-store-failure.sock", 1);
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");
    _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");

    const cases = [_]struct {
        kind: paneldrive.FailureKind,
        needle: []const u8,
    }{
        .{ .kind = .attach_failed, .needle = "attach failed" },
        .{ .kind = .origin_unreachable, .needle = "unreachable" },
        .{ .kind = .malformed_attach, .needle = "identity is malformed" },
        .{ .kind = .malformed_welcome, .needle = "welcome is malformed" },
        .{ .kind = .identity_mismatch, .needle = "does not match" },
        .{ .kind = .origin_timeout, .needle = "timed out" },
        .{ .kind = .no_compatible_gui, .needle = "no compatible GUI" },
        .{ .kind = .delivery_uncertain, .needle = "delivery is uncertain" },
        .{ .kind = .reply_timeout, .needle = "reply timed out" },
        .{ .kind = .disconnected, .needle = "disconnected" },
        .{ .kind = .malformed_reply, .needle = "malformed reply" },
    };
    for (cases) |case| {
        var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
        defer fake.deinit();
        var transport = UiTransport{
            .arena = arena,
            .backend = fake.backend(),
            .session = "exact-session",
            .mode = .mux_relay,
            .origin = .{
                .socket = try arena.dupe(u8, "/tmp/exact-store-failure.sock"),
                .session = "exact-session",
                .source = .environment,
            },
            .failure = .{ .kind = case.kind, .detail = "fixture" },
        };
        defer transport.deinit();
        const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
        try t.expect(store.err.len > 0);
        try t.expect(std.mem.indexOf(u8, store.err, case.needle) != null);
        try t.expect(std.mem.indexOf(u8, store.err, "refusing to downgrade") != null);
    }
}

test "exact persistence retains a previously validated lifetime scope after every failure class" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = c.setenv("SKETERM_MUX_SOCKET", "/tmp/exact-store-retained.sock", 1);
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");

    const failures = [_]paneldrive.FailureKind{
        .attach_failed,
        .origin_unreachable,
        .malformed_attach,
        .malformed_welcome,
        .identity_mismatch,
        .origin_timeout,
        .no_compatible_gui,
        .delivery_uncertain,
        .reply_timeout,
        .disconnected,
        .malformed_reply,
    };
    for (failures) |kind| {
        var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
        defer fake.deinit();
        var transport = UiTransport{
            .arena = arena,
            .backend = fake.backend(),
            .session = "exact-session",
            .mode = .mux_relay,
            .origin = .{
                .socket = try arena.dupe(u8, "/tmp/exact-store-retained.sock"),
                .session = "exact-session",
                .source = .environment,
            },
            .failure = .{ .kind = kind, .detail = "fixture" },
            .validated_store_scope = .{ .origin = .{
                .daemon_origin = "/tmp/exact-store-retained.sock",
                .origin_id = "10000000000000000000000000000001",
                .label = "exact-session",
            } },
        };
        defer transport.deinit();
        const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
        try t.expectEqualStrings("", store.err);
        switch (store.scope) {
            .origin => |exact| {
                try t.expectEqualStrings("10000000000000000000000000000001", exact.origin_id);
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "malformed inherited exact identity is an error rather than old-daemon evidence" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    _ = c.setenv("SKETERM_MUX_SOCKET", "/tmp/exact-store-malformed.sock", 1);
    _ = c.setenv("SKETERM_SESSION", "exact-session", 1);
    _ = c.setenv("SKETERM_SESSION_ORIGIN_ID", "not-an-origin-id", 1);
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");
    defer _ = c.unsetenv("SKETERM_SESSION");
    defer _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");

    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    var transport = UiTransport{
        .arena = arena,
        .backend = fake.backend(),
        .session = "exact-session",
        .mode = .mux_relay,
        .origin = .{
            .socket = try arena.dupe(u8, "/tmp/exact-store-malformed.sock"),
            .session = "exact-session",
            .source = .environment,
        },
    };
    defer transport.deinit();
    const store = uiStoreScope(&transport, UI_RELAY_CALL_MS);
    try t.expect(std.mem.indexOf(u8, store.err, "identity is malformed") != null);
    try t.expect(std.mem.indexOf(u8, store.err, "refusing to downgrade") != null);
}

test "exact origin falls back only to an explicit GUI after proven pre-delivery attach failure" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const old_source = mcp.srv_gui_socket_source;
    defer mcp.srv_gui_socket_source = old_source;
    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    var transport = UiTransport{
        .arena = arena_state.allocator(),
        .backend = fake.backend(),
        .session = "session",
        .mode = .mux_relay,
    };
    const exact = paneldrive.Origin{
        .socket = @constCast("/tmp/exact-origin.sock"),
        .session = "session",
        .source = .environment,
    };
    mcp.srv_gui_socket_source = .explicit;
    for ([_]paneldrive.FailureKind{ .legacy_daemon, .unsupported, .no_compatible_gui, .attach_failed, .malformed_attach }) |kind|
        try t.expect(transport.canFallbackDirect(exact, .{ .kind = kind, .detail = "pre" }));
    for ([_]paneldrive.FailureKind{ .identity_mismatch, .origin_unreachable, .origin_timeout, .malformed_welcome, .delivery_uncertain, .reply_timeout, .disconnected, .malformed_reply }) |kind|
        try t.expect(!transport.canFallbackDirect(exact, .{ .kind = kind, .detail = "unsafe" }));
    mcp.srv_gui_socket_source = .discovered;
    try t.expect(!transport.canFallbackDirect(exact, .{ .kind = .unsupported, .detail = "legacy" }));
}

test "a relayed uncertain-delivery verdict still reaches the tool result as uncertain" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const origin = paneldrive.Origin{
        .socket = @constCast("/tmp/origin.sock"),
        .session = "session",
        .source = .environment,
    };
    // paneldrive is the single validator now: a presenter reply carrying
    // failure_class=uncertain_delivery arrives here already classified, and
    // the tool-visible message must still say so and forbid a resend.
    const message = relayFailure(arena_state.allocator(), origin, .{
        .kind = .delivery_uncertain,
        .detail = "daemon reported failure_class=uncertain_delivery",
        .connection_usable = true,
    });
    try t.expect(std.mem.indexOf(u8, message, "delivery became uncertain") != null);
    try t.expect(std.mem.indexOf(u8, message, "mutation may have applied") != null);
    try t.expect(std.mem.indexOf(u8, message, "NOT resent automatically") != null);
    try t.expect(paneldrive.Failure.uncertain(.{ .kind = .malformed_reply, .detail = "InvalidPanelId" }));
}

test "relay to explicit direct fallback shares one deadline for ui_wait_event" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var scratch: UiScratch = undefined;
    try scratch.init("fallback-deadline", true);
    defer scratch.deinit();

    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-legacy-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try directDropListener(path);
    defer _ = c.close(listener);
    const server = try std.Thread.spawn(.{}, LegacyPanelDaemonScript.run, .{LegacyPanelDaemonScript{
        .listener = listener,
        .delay_us = 90_000,
    }});
    defer server.join();

    const old_pool = mcp.panel_pool;
    var pool = paneldrive.Pool.init(t.allocator);
    defer pool.deinit();
    mcp.panel_pool = &pool;
    defer mcp.panel_pool = old_pool;
    _ = c.setenv("SKETERM_MUX_SOCKET", path.ptr, 1);
    _ = c.setenv("SKETERM_SESSION", "legacy-session", 1);
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");
    defer _ = c.unsetenv("SKETERM_SESSION");
    _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");

    var fake = FakeBackend{
        .responses = &.{"{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[{\"seq\":1,\"component\":\"ok\",\"kind\":\"click\",\"value\":\"yes\",\"ts\":1}],\"cursor\":1,\"dropped_total\":0}"},
        .allocator = t.allocator,
    };
    defer fake.deinit();
    const response = handleMessage(arena_state.allocator(), fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":250}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, response, "yes") != null);
    try t.expectEqual(@as(usize, 1), fake.timeouts.items.len);
    try t.expect(fake.timeouts.items[0] > 0);
    try t.expect(fake.timeouts.items[0] < 210);
}

test "direct GUI write and reply loss preserve delivery phase" {
    const t = std.testing;
    var missing_buf: [256:0]u8 = undefined;
    const missing = try std.fmt.bufPrintZ(&missing_buf, "/tmp/sketerm-direct-missing-{d}.sock", .{c.getpid()});
    _ = c.unlink(missing.ptr);
    var unavailable = RealBackend{ .sock_path = missing };
    defer unavailable.client.deinit();
    switch (RealBackend.talkFor(@ptrCast(&unavailable), t.allocator, "{}", 250)) {
        .failure => |failure| try t.expectEqual(.pre_delivery, failure.delivery),
        .reply => |reply| {
            t.allocator.free(reply);
            return error.UnexpectedReply;
        },
    }

    const cases = [_]struct {
        suffix: []const u8,
        mode: DirectDropScript.Mode,
        bytes: usize,
    }{
        .{ .suffix = "partial", .mode = .after_prefix, .bytes = 2 << 20 },
        .{ .suffix = "full", .mode = .after_line, .bytes = 16 },
    };
    for (cases) |case| {
        var path_buf: [256:0]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-direct-{s}-{d}.sock", .{ case.suffix, c.getpid() });
        _ = c.unlink(path.ptr);
        defer _ = c.unlink(path.ptr);
        const listener = try directDropListener(path);
        defer _ = c.close(listener);
        const thread = try std.Thread.spawn(.{}, DirectDropScript.run, .{DirectDropScript{
            .listener = listener,
            .mode = case.mode,
        }});
        const line = try t.allocator.alloc(u8, case.bytes);
        defer t.allocator.free(line);
        @memset(line, 'x');
        var backend = RealBackend{ .sock_path = path };
        defer backend.client.deinit();
        const result = RealBackend.talkFor(@ptrCast(&backend), t.allocator, line, 2_000);
        switch (result) {
            .failure => |failure| try t.expectEqual(.uncertain_delivery, failure.delivery),
            .reply => |reply| {
                t.allocator.free(reply);
                return error.UnexpectedReply;
            },
        }
        thread.join();
    }
}

test "expired direct deadlines dispatch neither mutations nor event drains" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    var transport = UiTransport{
        .arena = arena_state.allocator(),
        .backend = fake.backend(),
        .session = "s",
        .mode = .gui_socket,
    };
    const expired = clock.nowMs() - 1;
    for ([_]protocol.Request{
        .{ .cmd = "panel-patch", .panel_id = 1, .patch = "[]" },
        .{ .cmd = "panel-events", .panel_id = 1 },
    }) |request_value| {
        const reply = transport.directUntil(request_value, expired);
        try t.expect(!reply.ok);
        try t.expectEqual(IpcDelivery.pre_delivery, reply.delivery);
        try t.expect(std.mem.indexOf(u8, reply.err, "resend_safe=true") != null);
    }
    try t.expectEqual(@as(usize, 0), fake.requests.items.len);

    var path_buf: [256:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-direct-expired-{d}.sock", .{c.getpid()});
    _ = c.unlink(path.ptr);
    defer _ = c.unlink(path.ptr);
    const listener = try directDropListener(path);
    defer _ = c.close(listener);
    var backend = RealBackend{ .sock_path = path };
    defer backend.client.deinit();
    switch (RealBackend.talkFor(@ptrCast(&backend), t.allocator, "mutation", 0)) {
        .failure => |failure| try t.expectEqual(.pre_delivery, failure.delivery),
        .reply => |response| {
            t.allocator.free(response);
            return error.UnexpectedReply;
        },
    }
    var pfd = c.struct_pollfd{ .fd = listener, .events = c.POLLIN, .revents = 0 };
    try t.expectEqual(@as(c_int, 0), c.poll(&pfd, 1, 0));
}

test "direct mutation and event-drain reply loss are never described as missed-nothing" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const failures = [_]?DirectTalkFailure{
        .{ .err = error.NoResponse, .delivery = .uncertain_delivery },
        .{ .err = error.NoResponse, .delivery = .uncertain_delivery },
        .{ .err = error.ConnectFailed, .delivery = .pre_delivery },
    };
    var fake = FakeBackend{
        .responses = &.{},
        .talk_failures = &failures,
        .allocator = t.allocator,
    };
    defer fake.deinit();
    var transport = UiTransport{
        .arena = arena_state.allocator(),
        .backend = fake.backend(),
        .session = "s",
        .mode = .gui_socket,
    };
    const mutation = transport.direct(.{ .cmd = "panel-patch", .panel_id = 1, .patch = "[]" }, 1_000);
    try t.expect(!mutation.ok);
    try t.expect(std.mem.indexOf(u8, mutation.err, "mutation_may_have_applied=true") != null);
    try t.expect(std.mem.indexOf(u8, mutation.err, "resend_safe=false") != null);
    const events = transport.direct(.{ .cmd = "panel-events", .panel_id = 1 }, 1_000);
    try t.expect(!events.ok);
    try t.expect(std.mem.indexOf(u8, events.err, "events_may_have_been_drained=true") != null);
    try t.expect(std.mem.indexOf(u8, events.err, "Nothing was missed") == null);
    const safe = transport.direct(.{ .cmd = "panel-show", .document = "{}" }, 1_000);
    try t.expect(!safe.ok);
    try t.expect(std.mem.indexOf(u8, safe.err, "failure_class=pre_delivery") != null);
    try t.expect(std.mem.indexOf(u8, safe.err, "mutation_may_have_applied=false") != null);
}

test "a lost reliable event reply consumed nothing, a lost legacy drain may have" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var scratch: UiScratch = undefined;
    try scratch.init("event-loss", true);
    defer scratch.deinit();
    const failures = [_]?DirectTalkFailure{
        .{ .err = error.NoResponse, .delivery = .uncertain_delivery },
    };
    var fake = FakeBackend{
        .responses = &.{},
        .talk_failures = &failures,
        .allocator = t.allocator,
    };
    defer fake.deinit();
    const response = handleMessage(arena_state.allocator(), fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"session":"","timeout_ms":5000}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, response, "isError") != null);
    try t.expect(std.mem.indexOf(u8, response, "events_may_have_been_drained=false") != null);
    try t.expect(std.mem.indexOf(u8, response, "resend_safe=true") != null);
    try t.expect(std.mem.indexOf(u8, response, "may have been drained") == null);
    try t.expectEqual(@as(usize, 1), fake.requests.items.len);
    try t.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"cmd\":\"panel-events-reliable\"") != null);

    // A GUI without the reliable read: only there can a lost reply have
    // drained interactions, and only there is it said.
    resetEventCursors();
    const legacy_failures = [_]?DirectTalkFailure{
        null,
        .{ .err = error.NoResponse, .delivery = .uncertain_delivery },
    };
    var legacy = FakeBackend{
        .responses = &.{"{\"ok\":false,\"error\":\"unknown panel command\"}"},
        .talk_failures = &legacy_failures,
        .allocator = t.allocator,
    };
    defer legacy.deinit();
    const drained = handleMessage(arena_state.allocator(), legacy.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"session":"","timeout_ms":5000}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, drained, "isError") != null);
    try t.expect(std.mem.indexOf(u8, drained, "events_may_have_been_drained=true") != null);
    try t.expect(std.mem.indexOf(u8, drained, "Events may have been drained") != null);
    try t.expectEqual(@as(usize, 2), legacy.requests.items.len);
    try t.expect(std.mem.indexOf(u8, legacy.requests.items[1], "\"cmd\":\"panel-events\"") != null);
}

test "the reliable read acknowledges exactly what the previous wait returned" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("event-ack", true);
    defer scratch.deinit();
    var fake = FakeBackend{
        .responses = &.{
            // wait 1: two interactions, nothing acknowledged yet
            "{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[{\"seq\":1,\"component\":\"a\",\"kind\":\"click\",\"value\":null,\"ts\":1},{\"seq\":2,\"component\":\"b\",\"kind\":\"change\",\"value\":true,\"ts\":2}],\"cursor\":2,\"dropped_total\":0}",
            // wait 2: acknowledges 2, then the panel was REPLACED under the same id
            "{\"ok\":false,\"error\":\"panel event epoch changed; acknowledgement was not applied\",\"error_code\":\"event_epoch_mismatch\"}",
            // ... so the new lifetime is read from nothing, at once
            "{\"ok\":true,\"event_epoch\":\"20000000000000000000000000000002\",\"events\":[{\"seq\":1,\"component\":\"c\",\"kind\":\"submit\",\"value\":\"x\",\"ts\":3}],\"cursor\":1,\"dropped_total\":1}",
        },
        .allocator = t.allocator,
    };
    defer fake.deinit();
    const first = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":5000}}}
    ).?;
    {
        const shape = try expectToolResultShape(arena, "ui_wait_event", try rpcToolResult(arena, first));
        const sc = shape.object.get("structuredContent").?.object;
        try t.expectEqual(@as(usize, 2), sc.get("events").?.array.items.len);
        try t.expect(sc.get("reliable").?.bool);
    }
    try t.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"ack\":0") != null);
    try t.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"event_epoch\":null") != null);

    const second = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":5000}}}
    ).?;
    try t.expectEqual(@as(usize, 3), fake.requests.items.len);
    try t.expect(std.mem.indexOf(u8, fake.requests.items[1], "\"ack\":2") != null);
    try t.expect(std.mem.indexOf(u8, fake.requests.items[1], "10000000000000000000000000000001") != null);
    try t.expect(std.mem.indexOf(u8, fake.requests.items[2], "\"ack\":0") != null);
    {
        const shape = try expectToolResultShape(arena, "ui_wait_event", try rpcToolResult(arena, second));
        const sc = shape.object.get("structuredContent").?.object;
        const evs = sc.get("events").?.array.items;
        try t.expectEqual(@as(usize, 1), evs.len);
        try t.expectEqualStrings("x", evs[0].object.get("value").?.string);
        try t.expectEqual(@as(i64, 1), sc.get("dropped").?.integer);
    }
}

test "ui_wait_event drains only for a GUI that predates the reliable read" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("event-legacy", true);
    defer scratch.deinit();
    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":false,\"error\":\"unknown panel command\"}",
            "{\"ok\":true,\"events\":[{\"component\":\"ok\",\"kind\":\"click\",\"value\":\"go\",\"ts\":1}],\"dropped\":0}",
            "{\"ok\":true,\"events\":[],\"dropped\":0}",
        },
        .allocator = t.allocator,
    };
    defer fake.deinit();
    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":3,"timeout_ms":5000}}}
    ).?;
    const shape = try expectToolResultShape(arena, "ui_wait_event", try rpcToolResult(arena, resp));
    const sc = shape.object.get("structuredContent").?.object;
    try t.expect(!sc.get("reliable").?.bool);
    try t.expectEqualStrings("go", sc.get("events").?.array.items[0].object.get("value").?.string);
    try t.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"cmd\":\"panel-events-reliable\"") != null);
    try t.expect(std.mem.indexOf(u8, fake.requests.items[1], "\"cmd\":\"panel-events\"") != null);
    // The verdict is remembered: the next wait does not probe again.
    _ = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":3,"timeout_ms":50}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, fake.requests.items[2], "\"cmd\":\"panel-events\"") != null);
}

test "ui_wait_event distinguishes pre-delivery unavailability from confirmed closure" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var scratch: UiScratch = undefined;
    try scratch.init("event-delivery-state", true);
    defer scratch.deinit();

    const failures = [_]?DirectTalkFailure{
        .{ .err = error.ConnectFailed, .delivery = .pre_delivery },
    };
    var unavailable = FakeBackend{
        .responses = &.{},
        .talk_failures = &failures,
        .allocator = t.allocator,
    };
    defer unavailable.deinit();
    const unknown = handleMessage(arena_state.allocator(), unavailable.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"session":"","timeout_ms":5000}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, unknown, "isError") != null);
    try t.expect(std.mem.indexOf(u8, unknown, "failure_class=pre_delivery") != null);
    try t.expect(std.mem.indexOf(u8, unknown, "events_may_have_been_drained=false") != null);
    try t.expect(std.mem.indexOf(u8, unknown, "resend_safe=true") != null);
    try t.expect(std.mem.indexOf(u8, unknown, "UNKNOWN") != null);
    try t.expect(std.mem.indexOf(u8, unknown, "confirmed") == null);
    try t.expect(std.mem.indexOf(u8, unknown, "Nothing was missed") == null);

    var closed = FakeBackend{
        .responses = &.{"{\"ok\":false,\"error\":\"no such panel\"}"},
        .allocator = t.allocator,
    };
    defer closed.deinit();
    const confirmed = handleMessage(arena_state.allocator(), closed.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"session":"","timeout_ms":5000}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, confirmed, "isError") != null);
    try t.expect(std.mem.indexOf(u8, confirmed, "confirmed") != null);
    try t.expect(std.mem.indexOf(u8, confirmed, "not live") != null);
    try t.expect(std.mem.indexOf(u8, confirmed, "UNKNOWN") == null);
}

test "maximum panel document crosses the direct GUI request boundary intact" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const prefix = "{\"root\":\"t\",\"components\":{\"t\":{\"type\":\"text\",\"text\":\"ok\"}},\"padding\":\"";
    const suffix = "\"}";
    const document = try arena.alloc(u8, paneldoc.MAX_JSON_BYTES);
    @memcpy(document[0..prefix.len], prefix);
    const body = document[prefix.len .. document.len - suffix.len];
    var i: usize = 0;
    while (i + 1 < body.len) : (i += 2) {
        body[i] = '\\';
        body[i + 1] = '"';
    }
    if (i < body.len) body[i] = 'x';
    @memcpy(document[document.len - suffix.len ..], suffix);
    var parsed_doc = try paneldoc.Document.parse(arena, document, null);
    defer parsed_doc.deinit();

    var fake = FakeBackend{
        .responses = &.{"{\"ok\":true,\"panel_id\":17}"},
        .allocator = t.allocator,
    };
    defer fake.deinit();
    var transport = UiTransport{
        .arena = arena,
        .backend = fake.backend(),
        .session = "boundary-session",
        .mode = .gui_socket,
    };
    const reply = transport.direct(.{
        .cmd = "panel-show",
        .session = "boundary-session",
        .name = "boundary",
        .target = "tab",
        .document = document,
    }, 5_000);
    try t.expect(reply.ok);
    try t.expectEqual(@as(usize, 1), fake.requests.items.len);
    const sent = fake.requests.items[0];
    try t.expect(sent.len > (1 << 20));
    try t.expect(sent.len <= protocol.MAX_LINE);
    var parsed = try protocol.parseRequest(arena, sent);
    defer parsed.deinit();
    try t.expectEqual(document.len, parsed.value.document.?.len);
    try t.expectEqualStrings(document, parsed.value.document.?);
}

test "ui_wait_event polls instead of blocking the GUI, and reports drops" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("wait", true);
    defer scratch.deinit();

    // panel-events answers immediately every time (it runs on the GLib
    // main loop); the WAIT is this tool's poll loop.
    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[],\"cursor\":0,\"dropped_total\":0}",
            "{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[],\"cursor\":0,\"dropped_total\":2}",
            "{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[{\"seq\":3,\"component\":\"ok\",\"kind\":\"click\",\"value\":\"approve\",\"ts\":42}],\"cursor\":3,\"dropped_total\":2}",
        },
        .allocator = std.testing.allocator,
    };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":5000}}}
    ).?;
    try std.testing.expectEqual(@as(usize, 3), fake.requests.items.len);
    try std.testing.expect(std.mem.indexOf(u8, fake.requests.items[0], "\"cmd\":\"panel-events-reliable\"") != null);
    {
        const shape = try expectToolResultShape(arena, "ui_wait_event", try rpcToolResult(arena, resp));
        const sc = shape.object.get("structuredContent").?.object;
        const evs = sc.get("events").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), evs.len);
        try std.testing.expectEqualStrings("approve", evs[0].object.get("value").?.string);
        // The drop counter seen on an earlier poll is not lost.
        try std.testing.expectEqual(@as(i64, 2), sc.get("dropped").?.integer);
        try std.testing.expect(!sc.get("timed_out").?.bool);
        const text = shape.object.get("content").?.array.items[0].object.get("text").?.string;
        try std.testing.expect(std.mem.indexOf(u8, text, "OLDER interaction(s) were discarded") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "click ok = approve") != null);
    }
    // Two poll ticks were slept, not spun.
    try std.testing.expectEqual(@as(i64, 2 * UI_POLL_MS), fake.clock_ms);
    try std.testing.expectEqualSlices(i64, &.{ 5000, 4900, 4800 }, fake.timeouts.items);
}

test "ui_wait_event times out honestly and clamps the budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("timeout", true);
    defer scratch.deinit();

    var bufs: [4][]const u8 = @splat("{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[],\"cursor\":0,\"dropped_total\":0}");
    var fake = FakeBackend{ .responses = &bufs, .allocator = std.testing.allocator };
    defer fake.deinit();

    const resp = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":250}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, resp, "isError") == null);
    {
        const shape = try expectToolResultShape(arena, "ui_wait_event", try rpcToolResult(arena, resp));
        const sc = shape.object.get("structuredContent").?.object;
        try std.testing.expect(sc.get("timed_out").?.bool);
        try std.testing.expectEqual(@as(usize, 0), sc.get("events").?.array.items.len);
        const text = shape.object.get("content").?.array.items[0].object.get("text").?.string;
        try std.testing.expect(std.mem.indexOf(u8, text, "still showing") != null);
    }
    try std.testing.expectEqualSlices(i64, &.{ 250, 150, 50 }, fake.timeouts.items);

    // A wait longer than the watchdog allows is clamped, not promised.
    var bufs2: [1][]const u8 = @splat("{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[{\"seq\":1,\"component\":\"s\",\"kind\":\"change\",\"value\":3,\"ts\":1}],\"cursor\":1,\"dropped_total\":0}");
    var fake2 = FakeBackend{ .responses = &bufs2, .allocator = std.testing.allocator };
    defer fake2.deinit();
    const clamped = handleMessage(arena, fake2.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":999999}}}
    ).?;
    {
        const shape = try expectToolResultShape(arena, "ui_wait_event", try rpcToolResult(arena, clamped));
        const evs = shape.object.get("structuredContent").?.object.get("events").?.array.items;
        try std.testing.expectEqualStrings("change", evs[0].object.get("kind").?.string);
    }

    // A panel that went away ends the wait at once, and says so.
    var bufs3: [1][]const u8 = @splat("{\"ok\":false,\"error\":\"no such panel\"}");
    var fake3 = FakeBackend{ .responses = &bufs3, .allocator = std.testing.allocator };
    defer fake3.deinit();
    const gone = handleMessage(arena, fake3.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":7,"timeout_ms":60000}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, gone, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone, "confirmed") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone, "not live") != null);
    try std.testing.expect(std.mem.indexOf(u8, gone, "UNKNOWN") == null);
}

test "ui_wait_event includes name resolution and every exchange in one deadline" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("whole-deadline", true);
    defer scratch.deinit();

    var fake = FakeBackend{
        .responses = &.{
            "{\"ok\":true,\"panels\":[{\"panel_id\":9,\"name\":\"slow\"}]}",
            "{\"ok\":true,\"event_epoch\":\"10000000000000000000000000000001\",\"events\":[],\"cursor\":0,\"dropped_total\":0}",
        },
        .talk_delays_ms = &.{ 120, 80 },
        .allocator = t.allocator,
    };
    defer fake.deinit();
    const response = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"name":"slow","timeout_ms":250}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, response, "timed_out") != null);
    try t.expect(std.mem.indexOf(u8, response, "isError") == null);
    try t.expectEqual(@as(i64, 250), fake.clock_ms);
    try t.expectEqualSlices(i64, &.{ 250, 130 }, fake.timeouts.items);
    try t.expectEqual(@as(usize, 2), fake.requests.items.len);
}

test "ui_* tools need live transport while store-only behavior remains" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("nogui", false);
    defer scratch.deinit();

    var fake = FakeBackend{ .responses = &.{}, .allocator = std.testing.allocator };
    defer fake.deinit();

    for ([_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_show","arguments":{"name":"x","document":{}}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_close","arguments":{"panel_id":1}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_wait_event","arguments":{"panel_id":1}}}
        ,
    }) |msg| {
        const resp = handleMessage(arena, fake.backend(), msg).?;
        try std.testing.expect(std.mem.indexOf(u8, resp, "isError") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp, "panel transport") != null);
    }
    // Nothing was even attempted on the socket.
    try std.testing.expectEqual(@as(usize, 0), fake.requests.items.len);

    // The saved half is independent of the GUI: save, list, delete.
    const saved = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"kept","session":"s2","document":{"title":"Kept","root":"t","components":{"t":{"type":"text","text":"hi"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, saved, "isError") == null);

    const listed = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"ui_panels","arguments":{"session":"s2"}}}
    ).?;
    {
        const shape = try expectToolResultShape(arena, "ui_panels", try rpcToolResult(arena, listed));
        const sc = shape.object.get("structuredContent").?.object;
        try std.testing.expectEqual(std.json.Value{ .null = {} }, sc.get("live").?);
        try std.testing.expect(std.mem.indexOf(u8, sc.get("live_error").?.string, "panel transport") != null);
        try std.testing.expectEqual(@as(usize, 1), sc.get("saved").?.array.items.len);
    }
    try std.testing.expect(std.mem.indexOf(u8, listed, "kept") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "Kept") != null);

    const deleted = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"ui_delete","arguments":{"name":"kept","session":"s2"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, deleted, "isError") == null);
    try std.testing.expect(!panelstore.existsScoped(arena, .{ .session = "s2" }, "kept"));

    // Deleting what is not there names the panel and the session.
    const again = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"ui_delete","arguments":{"name":"kept","session":"s2"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, again, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, again, "kept") != null);
}

test "store-only panel tools refuse an unidentified exact daemon environment" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var scratch: UiScratch = undefined;
    try scratch.init("pre-panel-store", false);
    defer scratch.deinit();
    const old_pool = mcp.panel_pool;
    mcp.panel_pool = null;
    defer mcp.panel_pool = old_pool;
    _ = c.setenv("SKETERM_MUX_SOCKET", "/tmp/exact-pre-panel/mux.sock", 1);
    _ = c.setenv("SKETERM_SESSION", "old-session", 1);
    _ = c.unsetenv("SKETERM_SESSION_ORIGIN_ID");
    defer _ = c.unsetenv("SKETERM_MUX_SOCKET");
    defer _ = c.unsetenv("SKETERM_SESSION");

    var fake = FakeBackend{ .responses = &.{}, .allocator = t.allocator };
    defer fake.deinit();
    const saved = handleMessage(arena_state.allocator(), fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"offline","document":{"title":"Offline","root":"r","components":{"r":{"type":"text","text":"saved"}}}}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, saved, "isError") != null);
    try t.expect(std.mem.indexOf(u8, saved, "refusing to downgrade") != null);
    const listed = handleMessage(arena_state.allocator(), fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_panels","arguments":{}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, listed, "saved_error") != null);
    try t.expect(std.mem.indexOf(u8, listed, "refusing to downgrade") != null);
    const deleted = handleMessage(arena_state.allocator(), fake.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_delete","arguments":{"name":"offline"}}}
    ).?;
    try t.expect(std.mem.indexOf(u8, deleted, "isError") != null);
    try t.expect(std.mem.indexOf(u8, deleted, "refusing to downgrade") != null);
    try t.expectEqual(@as(usize, 0), fake.requests.items.len);

    try t.expect(!panelstore.existsScoped(t.allocator, .{ .session = "old-session" }, "offline"));
}

test "ui panels are session-scoped, including a session with a space" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("scope", false);
    defer scratch.deinit();

    var fake = FakeBackend{ .responses = &.{}, .allocator = std.testing.allocator };
    defer fake.deinit();

    // A legal daemon session name the old charset rule would have
    // rejected outright.
    const save_a =
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"p","session":"my work","document":{"title":"Mine","root":"t","components":{"t":{"type":"text","text":"a"}}}}}}
    ;
    try std.testing.expect(std.mem.indexOf(u8, handleMessage(arena, fake.backend(), save_a).?, "isError") == null);
    const save_b =
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"p","session":"other","document":{"title":"Theirs","root":"t","components":{"t":{"type":"text","text":"b"}}}}}}
    ;
    try std.testing.expect(std.mem.indexOf(u8, handleMessage(arena, fake.backend(), save_b).?, "isError") == null);

    const mine = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"ui_panels","arguments":{"session":"my work"}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, mine, "Mine") != null);
    try std.testing.expect(std.mem.indexOf(u8, mine, "Theirs") == null);
}

test "explicit empty ui session selects sessionless despite inherited session" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var scratch: UiScratch = undefined;
    try scratch.init("explicit-empty", false);
    defer scratch.deinit();
    _ = c.setenv("SKETERM_SESSION", "inherited-session", 1);
    defer _ = c.unsetenv("SKETERM_SESSION");

    var fake = FakeBackend{ .responses = &.{}, .allocator = std.testing.allocator };
    defer fake.deinit();
    const explicit_empty = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"empty","session":"","document":{"root":"t","components":{"t":{"type":"text","text":"none"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, explicit_empty, "isError") == null);
    try std.testing.expect(panelstore.existsScoped(arena, .sessionless, "empty"));
    try std.testing.expect(!panelstore.existsScoped(arena, .{ .session = "inherited-session" }, "empty"));

    const absent = handleMessage(arena, fake.backend(),
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ui_save","arguments":{"name":"inherited","document":{"root":"t","components":{"t":{"type":"text","text":"env"}}}}}}
    ).?;
    try std.testing.expect(std.mem.indexOf(u8, absent, "isError") == null);
    try std.testing.expect(panelstore.existsScoped(arena, .{ .session = "inherited-session" }, "inherited"));
    try std.testing.expect(!panelstore.existsScoped(arena, .sessionless, "inherited"));
}

test "panel failures are typed by delivery phase, then by their code" {
    const t = std.testing;
    const pre = IpcReply{ .ok = false, .value = .null, .err = "x", .delivery = .pre_delivery };
    try t.expectEqual(ErrCode.unavailable, uiFailCode(pre));
    const uncertain = IpcReply{ .ok = false, .value = .null, .err = "x", .delivery = .uncertain_delivery };
    try t.expectEqual(ErrCode.io_failed, uiFailCode(uncertain));
    const coded = IpcReply{ .ok = false, .value = .null, .err = "anything", .code = .not_found };
    try t.expectEqual(ErrCode.not_found, uiFailCode(coded));
    const own = IpcReply{ .ok = false, .value = .null, .err = UI_NEEDS_TRANSPORT, .code = .unavailable };
    try t.expectEqual(ErrCode.unavailable, uiFailCode(own));
    // A GUI too old to send codes is still read by its prose.
    const gone = IpcReply{ .ok = false, .value = .null, .err = "no such panel" };
    try t.expectEqual(ErrCode.not_found, uiFailCode(gone));
    const odd = IpcReply{ .ok = false, .value = .null, .err = "the presenter said something new" };
    try t.expectEqual(ErrCode.failed, uiFailCode(odd));

    // Addressing is the CALLER's fault or a missing panel, never io.
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bad = try uiResolveErr(arena, .{ .err = "panel_id must be a positive integer (the handle ui_show returned)", .code = .invalid_args });
    try t.expect(std.mem.indexOf(u8, bad, "\"code\":\"invalid_args\"") != null);
}

test "ui_wait_event's one result shape: timeout and events, both isError:false" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const idle = try uiEventsResult(arena, 7, 250, null, 0, 250, .reliable);
    const iparsed = try expectToolResultShape(arena, "ui_wait_event", idle);
    try t.expect(iparsed.object.get("isError") == null);
    const isc = iparsed.object.get("structuredContent").?.object;
    try t.expect(isc.get("timed_out").?.bool);
    try t.expectEqual(@as(usize, 0), isc.get("events").?.array.items.len);

    const evs = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\[{"seq":4,"component":"amount","kind":"change","value":12.5,"ts":9}]
    , .{});
    const got = try uiEventsResult(arena, 7, 90, evs, 3, 5000, .drain);
    const parsed = try expectToolResultShape(arena, "ui_wait_event", got);
    const sc = parsed.object.get("structuredContent").?.object;
    try t.expect(!sc.get("timed_out").?.bool);
    try t.expectEqual(@as(i64, 1), sc.get("count").?.integer);
    try t.expectEqual(@as(i64, 3), sc.get("dropped").?.integer);
    const text = parsed.object.get("content").?.array.items[0].object.get("text").?.string;
    try t.expect(std.mem.indexOf(u8, text, "--- events ---\n4 change amount = 12.5") != null);
}
