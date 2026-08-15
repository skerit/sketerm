//! Hosting and addressing for panel documents: the `panel-*` half of
//! the GUI control socket.
//!
//! A panel is a declarative document (src/ui/panel/doc.zig) rendered by
//! a `PanelView` and hosted either as a PANE FACE (on the requesting
//! pane, or on a fresh tab's pane) or in a STANDALONE WINDOW
//! (ui/panelwin.zig). Which of the three a caller gets is the `target`
//! parameter; everything else about a panel is identical across them.
//!
//! Direct GUI-socket panels retain their `(session, name)` keys. Relayed
//! panels are scoped by the immutable mux session `origin_id` alone: every
//! viewer of one session origin in this GUI process shares one scope and sees
//! the same panels regardless of which attachment receives a routed request.
//! Showing a name that already exists in one scope replaces its document in
//! place rather than opening a second window.
//!
//! Liveness: the registry entry IS the pane face's context pointer, so
//! there is exactly one place a panel can die — the face's destroy
//! trampoline (reached from `Pane.severFaces` for every pane teardown
//! path) and, for a window panel, the window's ::destroy. Both
//! unregister before anything is freed, so a `panel_id` never outlives
//! the widgets behind it.
//!
//! Threading: registry/document/widget commits run on GTK; bounded workers do
//! transport setup, file reads, cache IO and decode. Panel event commands NEVER
//! blocks — it drains whatever the queue
//! holds and answers immediately, even with nothing. Blocking
//! `ui_wait_event` semantics belong to the MCP layer polling this
//! command; `events.Queue.waitAny` is for a thread that may sleep and
//! must not be called from here.

const std = @import("std");
const c = @import("../c.zig").c;
const protocol = @import("../ipc/protocol.zig");
const panelstore = @import("../ipc/panelstore.zig");
const term_mod = @import("../terminal.zig");
const Terminal = term_mod.Terminal;
const DrainHandle = term_mod.DrainHandle;
const mux_client = @import("../mux/client.zig");
const mux_daemon = @import("../mux/daemon.zig");
const panelrpc = @import("../mux/panelrpc.zig");
const mux_wire = @import("../mux/wire.zig");
const Pane = @import("pane.zig").Pane;
const winmod = @import("window.zig");
const Window = winmod.Window;
const remotectl = @import("remotectl.zig");
const Doc = @import("panel/doc.zig");
const assets = @import("panel/assets.zig");
const canary = @import("panel/canary.zig");
const events = @import("panel/events.zig");
const PanelView = @import("panel/view.zig").PanelView;
const PanelWindow = @import("panelwin.zig").PanelWindow;
const cast = @import("../util/cast.zig");

pub const Target = enum {
    /// The requesting pane itself wears the panel face.
    pane,
    /// A new tab in the requesting pane's window, whose pane wears it.
    tab,
    /// A standalone panel window.
    window,

    pub fn fromName(s: ?[]const u8) ?Target {
        const want = s orelse return .tab;
        if (want.len == 0) return .tab;
        return std.meta.stringToEnum(Target, want);
    }

    pub fn name(self: Target) []const u8 {
        return @tagName(self);
    }
};

/// How "no session at all" travels: a caller with no session identity
/// (a script talking to the socket from outside any pane) sends
/// `"session":""`, and gets `""` back in every reply that echoes one.
///
/// It is not a session NAME — the daemon never issues an empty one,
/// and nothing here or in the store ever treats it as one: in code the
/// scope is `?[]const u8` and this is only its wire spelling, which is
/// what keeps a sessionless panel and its saved document (a directory
/// of its own, `panelstore.NO_SESSION_DIR`) under the same key.
/// Distinct from an ABSENT `session` field, which means "scope me to
/// the requesting pane".
pub const NO_SESSION_WIRE: []const u8 = "";

/// One live panel. Heap-allocated and pointer-stable: it doubles as
/// the pane face's context, so its address is handed to GTK.
pub const Entry = struct {
    pub const MAGIC: u32 = 0x504E4C45; // "PNLE"
    /// Detector only (canary.zig): the face/window destroy trampolines
    /// are what actually own this allocation.
    magic: u32 = MAGIC,
    allocator: std.mem.Allocator,
    panel_id: u32,
    /// Random identity for this live entry's reliable event sequence space.
    event_epoch: panelrpc.EventEpoch,
    /// Owned.
    name: []u8,
    /// Owned. `null` = the caller had no session identity.
    session: ?[]u8,
    /// Direct GUI requests and one exact relayed session-origin scope are
    /// disjoint namespaces. There is deliberately no wildcard scope.
    scope: Scope = .direct,
    target: Target,
    view: *PanelView,
    /// Pane hosting the face (.pane / .tab targets). Valid for as long
    /// as the entry is registered.
    pane: ?*Pane = null,
    /// Window hosting it (.window target).
    win: ?*PanelWindow = null,
    /// Selected during pane-wide teardown, consumed after the old wrapper has
    /// unparented the face but before the face context would normally die.
    rehost_pane: ?*Pane = null,
    closing: bool = false,
    /// Direct local-image workers use the originating terminal only as a
    /// lifetime fence; relay entries carry their process/session scope.
    asset_origin: ?*DrainHandle = null,

    fn destroy(self: *Entry) void {
        const a = self.allocator;
        a.free(self.name);
        if (self.session) |sess| a.free(sess);
        canary.poison(self);
        a.destroy(self);
    }
};

const RelayViewer = struct {
    drain: *DrainHandle,
    pane: ?*Pane,
};

const OpenSessionWaiter = struct {
    drain: *DrainHandle,
    generation: u64,
    request_id: u64,
};

const OpenSessionToken = struct {
    allocator: std.mem.Allocator,
    token: []u8,
    target_session: []u8,
    target_origin_id: mux_wire.SessionOriginId,
    waiters: std.ArrayListUnmanaged(OpenSessionWaiter) = .empty,
    reply: ?[]u8 = null,
    completed_serial: u64 = 0,

    fn deinit(self: *OpenSessionToken) void {
        self.waiters.deinit(self.allocator);
        if (self.reply) |reply| self.allocator.free(reply);
        self.allocator.free(self.token);
        self.allocator.free(self.target_session);
        self.allocator.destroy(self);
    }
};

const RelayScope = struct {
    origin_id: mux_daemon.SessionOriginId,
    viewers: std.ArrayListUnmanaged(RelayViewer) = .empty,
    open_session_tokens: std.ArrayListUnmanaged(*OpenSessionToken) = .empty,
    next_open_completion: u64 = 1,
};

const Scope = union(enum) {
    direct,
    relay: *RelayScope,
};

/// Process-global panel registry. All registry access happens on the main
/// thread — the detached workers below touch no registry/GTK state and hand
/// back via g_idle_add — and a panel is addressed by id from any window's
/// socket, so the registry is module-level exactly like
/// `remotectl.next_pane_id`.
var panels: std.ArrayListUnmanaged(*Entry) = .empty;
var next_panel_id: u32 = 1;
/// A scope outlives every job that names it: `releaseRelayScopeIfIdle`
/// refuses to free one while any viewer, hydration, queued operation, tab
/// job or registered panel still points at it.
var relay_scopes: std.ArrayListUnmanaged(*RelayScope) = .empty;

const HydrationAssetState = enum { queued, reading, cache_wait, caching, success, failed };
const HydrationReadSource = enum { remote, local };

const HydrationAsset = struct {
    pending: *Hydration,
    logical: []u8,
    state: HydrationAssetState = .queued,
    read_token: u32 = 0,
    read_limit: usize = 0,
    bytes_data: ?[]u8 = null,
    bytes_allocator: std.mem.Allocator,
    cache_path: ?[]u8 = null,
    hash: ?[64]u8 = null,
    prepared_lease: ?*assets.PreparedLease = null,
    bytes: u64 = 0,
    failure: ?[]u8 = null,
};

const Hydration = struct {
    allocator: std.mem.Allocator,
    id: u64,
    /// Relay operations serialize by session-origin scope; direct work leaves null.
    relay_scope: ?*RelayScope = null,
    origin: *DrainHandle,
    window: *Window,
    pane: ?*Pane,
    request_id: u64,
    request: []u8,
    assets: []HydrationAsset,
    read_source: HydrationReadSource,
    resolver: assets.Resolver,
    /// Non-zero for a direct GUI-socket/picker presentation that already
    /// committed its document and is waiting only for prepared local images.
    direct_panel_id: u32 = 0,
    deadline_ms: i64,
    total_bytes: u64 = 0,

    fn deinit(self: *Hydration) void {
        for (self.assets) |*asset| {
            self.allocator.free(asset.logical);
            if (asset.bytes_data) |bytes| asset.bytes_allocator.free(bytes);
            if (asset.cache_path) |path| std.heap.c_allocator.free(path);
            if (asset.prepared_lease) |lease| lease.release();
            if (asset.failure) |message| self.allocator.free(message);
        }
        self.allocator.free(self.assets);
        self.allocator.free(self.request);
        self.resolver.deinit();
        self.allocator.destroy(self);
    }
};

/// A relay mutation waiting behind work in the same exact presenter scope.
/// Show/patch documents are deliberately not prepared yet: an earlier patch
/// may change which logical image paths their final document contains.
const QueuedPanelOperation = struct {
    allocator: std.mem.Allocator,
    scope: *RelayScope,
    origin: *DrainHandle,
    window: *Window,
    pane: ?*Pane,
    request_id: u64,
    request: []u8,
    deadline_ms: i64,

    fn deinit(self: *QueuedPanelOperation) void {
        self.allocator.free(self.request);
        self.allocator.destroy(self);
    }
};

const CacheJob = struct {
    drain: *DrainHandle,
    pending_id: u64,
    asset_index: usize,
    nonce: u64,
    root: []u8,
    bytes: []u8,
    bytes_allocator: std.mem.Allocator,
    protected: [][64]u8,
    owns_bytes: bool = true,
    stored: ?assets.Stored = null,
    prepared: ?*c.GdkPixbuf = null,
    prepared_reservation: ?assets.ProcessPreparedReservation = null,
    failure: ?[]const u8 = null,
    /// Publishes every worker-written result before the GLib handback reads it.
    ready: std.atomic.Value(bool) = .init(false),
    /// Test-only delay captured on the main thread before the worker starts.
    test_delay_ms: u32 = 0,
    decode_started: std.atomic.Value(bool) = .init(false),

    fn deinit(self: *CacheJob) void {
        const allocator = std.heap.c_allocator;
        if (self.stored) |*stored| stored.deinit();
        if (self.prepared) |pixbuf| c.g_object_unref(@ptrCast(pixbuf));
        if (self.prepared_reservation) |*reservation| reservation.release();
        allocator.free(self.root);
        if (self.owns_bytes) self.bytes_allocator.free(self.bytes);
        allocator.free(self.protected);
        allocator.destroy(self);
    }
};

const LocalReadJob = struct {
    drain: *DrainHandle,
    pending_id: u64,
    asset_index: usize,
    path: []u8,
    limit: usize,
    deadline_ms: i64,
    bytes: ?[]u8 = null,
    failure: ?[]const u8 = null,
    ready: std.atomic.Value(bool) = .init(false),

    fn deinit(self: *LocalReadJob) void {
        const allocator = std.heap.c_allocator;
        allocator.free(self.path);
        if (self.bytes) |bytes| allocator.free(bytes);
        allocator.destroy(self);
    }
};

const CacheInitJob = struct {
    drain: *DrainHandle,
    cache: ?*assets.Cache = null,
    failure: ?[]const u8 = null,
    ready: std.atomic.Value(bool) = .init(false),
    test_delay_ms: u32 = 0,

    fn deinit(self: *CacheInitJob) void {
        const allocator = std.heap.c_allocator;
        if (self.cache) |cache| {
            cache.deinit();
            allocator.destroy(cache);
        }
        allocator.destroy(self);
    }
};

const PanelTabJob = struct {
    allocator: std.mem.Allocator,
    window: *Window,
    pane: ?*Pane,
    scope: *RelayScope,
    origin: *DrainHandle,
    generation: u64,
    request_id: u64,
    deadline_ms: i64,
    name: []u8,
    spawned_session: []u8,
    spawned_origin_id: mux_wire.SessionOriginId = undefined,
    spawned_origin_id_valid: bool = false,
    document: []u8,
    shell: []u8,
    term: []u8,
    color_term: []u8,
    ipc_path: []u8,
    wayland_display: []u8,
    pane_id: u32,
    login_shell: bool,
    report_assets: bool,
    resolver: assets.Resolver,
    canceled: std.atomic.Value(bool) = .init(false),
    /// Dedicated duplicate used only for cross-thread shutdown. The worker
    /// never closes it; main-thread deinit does so after the handback, making
    /// a loaded descriptor immune to reuse while cancellation is possible.
    cancel_fd: std.atomic.Value(c_int) = .init(-1),
    conn: ?@import("../mux/client.zig").Conn = null,
    snapshot: ?[]u8 = null,
    identity: @import("../mux/client.zig").AttachIdentity = .{},
    spawned: bool = false,
    failure: []const u8 = "panel tab setup failed",

    fn deinit(self: *PanelTabJob) void {
        const cancel_fd = self.cancel_fd.load(.acquire);
        if (cancel_fd >= 0) _ = c.close(cancel_fd);
        if (self.conn) |*conn| {
            if (self.spawned) conn.queueKill(.{
                .name = self.spawned_session,
                .origin_id = if (self.spawned_origin_id_valid) &self.spawned_origin_id else "",
            }) catch {};
            conn.deinit();
        }
        if (self.snapshot) |snapshot| self.allocator.free(snapshot);
        self.resolver.deinit();
        self.allocator.free(self.name);
        self.allocator.free(self.spawned_session);
        self.allocator.free(self.document);
        self.allocator.free(self.shell);
        self.allocator.free(self.term);
        self.allocator.free(self.color_term);
        self.allocator.free(self.ipc_path);
        self.allocator.free(self.wayland_display);
        self.allocator.destroy(self);
    }
};

const PanelOpenSessionJob = struct {
    allocator: std.mem.Allocator,
    window: *Window,
    pane: ?*Pane,
    scope: *RelayScope,
    token: *OpenSessionToken,
    origin: *DrainHandle,
    generation: u64,
    deadline_ms: i64,
    target_session: []u8,
    target_origin_id: mux_wire.SessionOriginId,
    /// Exact local daemon socket, or null for a remote transport.
    socket: ?[]u8,
    /// Source-derived reconnect/display transport spec. Null is the ordinary
    /// local daemon; a custom local daemon retains its source "sock:" spec.
    host: ?[]u8,
    port_range: []u8,
    canceled: std.atomic.Value(bool) = .init(false),
    cancel_fd: std.atomic.Value(c_int) = .init(-1),
    conn: ?mux_client.Conn = null,
    snapshot: ?[]u8 = null,
    identity: mux_client.AttachIdentity = .{},
    failure: [192]u8 = undefined,
    failure_len: usize = 0,

    fn setFailure(self: *PanelOpenSessionJob, message: []const u8) void {
        const n = @min(message.len, self.failure.len);
        @memcpy(self.failure[0..n], message[0..n]);
        self.failure_len = n;
    }

    fn failureMessage(self: *const PanelOpenSessionJob) []const u8 {
        return if (self.failure_len > 0)
            self.failure[0..self.failure_len]
        else
            "panel session open failed";
    }

    fn deinit(self: *PanelOpenSessionJob) void {
        const cancel_fd = self.cancel_fd.load(.acquire);
        if (cancel_fd >= 0) _ = c.close(cancel_fd);
        if (self.conn) |*conn| conn.deinit();
        if (self.snapshot) |snapshot| self.allocator.free(snapshot);
        self.allocator.free(self.target_session);
        if (self.socket) |socket| self.allocator.free(socket);
        if (self.host) |host| self.allocator.free(host);
        if (self.port_range.len > 0) self.allocator.free(self.port_range);
        self.allocator.destroy(self);
    }
};

var hydrations: std.ArrayListUnmanaged(*Hydration) = .empty;
var queued_panel_operations: std.ArrayListUnmanaged(*QueuedPanelOperation) = .empty;
var next_hydration_id: u64 = 1;
var hydration_timer: c_uint = 0;
var active_cache_jobs: usize = 0;
var active_local_read_jobs: usize = 0;
var panel_asset_cache: ?*assets.Cache = null;
var cache_init_active = false;
var cache_store_lock: std.atomic.Value(bool) = .init(false);
var panel_tab_jobs: std.ArrayListUnmanaged(*PanelTabJob) = .empty;
var panel_open_session_jobs: std.ArrayListUnmanaged(*PanelOpenSessionJob) = .empty;

const MAX_PENDING_PANEL_OPERATIONS: usize = 16;
const MAX_PENDING_PER_ORIGIN: usize = 4;
const MAX_OPEN_SESSION_COMPLETED: usize = 64;
const MAX_OPEN_SESSION_WAITERS: usize = 32;

fn register(allocator: std.mem.Allocator, entry: *Entry) !void {
    try panels.append(allocator, entry);
}

fn unregister(entry: *Entry) void {
    for (panels.items, 0..) |e, i| {
        if (e == entry) {
            _ = panels.orderedRemove(i);
            return;
        }
    }
}

fn sameScope(a: Scope, b: Scope) bool {
    return switch (a) {
        .direct => switch (b) {
            .direct => true,
            .relay => false,
        },
        .relay => |origin| switch (b) {
            .direct => false,
            .relay => |other| origin == other,
        },
    };
}

fn relayScope(scope: Scope) ?*RelayScope {
    return switch (scope) {
        .direct => null,
        .relay => |relay| relay,
    };
}

fn sameRelayKey(scope: *const RelayScope, origin_id: []const u8) bool {
    return std.mem.eql(u8, &scope.origin_id, origin_id);
}

/// Register one GUI viewer in the per-session-lifetime scope (keyed by the
/// session `origin_id` alone: every viewer of one session origin in this GUI
/// process shares one scope). Rewiring a Terminal is idempotent and reconnect
/// keeps the attachment.
pub fn attachOrigin(terminal: *Terminal, pane: ?*Pane) void {
    if (terminal.panel_scope_ctx) |ctx| {
        const scope: *RelayScope = @ptrCast(@alignCast(ctx));
        if (pane) |attached_pane| for (scope.viewers.items) |*viewer| {
            if (viewer.drain == terminal.drain) viewer.pane = attached_pane;
        };
        return;
    }
    const remote = terminal.remote orelse return;
    if (!remote.canSend() or remote.conn.panel_rpc < mux_wire.PANEL_RPC_VERSION or
        !mux_daemon.validSessionOriginId(remote.origin_id)) return;

    var scope: ?*RelayScope = null;
    for (relay_scopes.items) |candidate| if (sameRelayKey(candidate, remote.origin_id)) {
        scope = candidate;
        break;
    };
    if (scope == null) {
        const fresh = std.heap.c_allocator.create(RelayScope) catch return;
        fresh.* = .{
            .origin_id = remote.origin_id[0..mux_daemon.SESSION_ORIGIN_ID_LEN].*,
        };
        relay_scopes.append(std.heap.c_allocator, fresh) catch {
            std.heap.c_allocator.destroy(fresh);
            return;
        };
        scope = fresh;
    }
    scope.?.viewers.append(std.heap.c_allocator, .{
        .drain = terminal.drain,
        .pane = pane,
    }) catch {
        // A just-created scope has zero holders here and would otherwise
        // sit in relay_scopes forever; the idle release frees exactly that
        // case and refuses while anything still points at the scope.
        releaseRelayScopeIfIdle(scope.?);
        return;
    };
    terminal.panel_scope_ctx = @ptrCast(scope.?);
}

/// The scope a terminal is already attached to. Lookup only — teardown
/// paths must never construct one.
fn attachedRelayScope(terminal: *Terminal) ?*RelayScope {
    const ctx = terminal.panel_scope_ctx orelse return null;
    return @ptrCast(@alignCast(ctx));
}

fn relayScopeForTerminal(terminal: *Terminal) ?*RelayScope {
    if (terminal.panel_scope_ctx == null) attachOrigin(terminal, null);
    return attachedRelayScope(terminal);
}

/// Free a scope once nothing can resolve it any more. Detached workers hand
/// back through their job's `scope` pointer, so it has to outlive every job
/// that named it and not merely its viewers.
fn releaseRelayScopeIfIdle(scope: *RelayScope) void {
    if (scope.viewers.items.len != 0) return;
    for (hydrations.items) |pending| if (pending.relay_scope == scope) return;
    for (queued_panel_operations.items) |queued| if (queued.scope == scope) return;
    for (panel_tab_jobs.items) |job| if (job.scope == scope) return;
    for (panel_open_session_jobs.items) |job| if (job.scope == scope) return;
    for (panels.items) |entry| if (relayScope(entry.scope) == scope) return;
    for (relay_scopes.items, 0..) |candidate, i| {
        if (candidate != scope) continue;
        _ = relay_scopes.swapRemove(i);
        scope.viewers.deinit(std.heap.c_allocator);
        for (scope.open_session_tokens.items) |token| token.deinit();
        scope.open_session_tokens.deinit(std.heap.c_allocator);
        std.heap.c_allocator.destroy(scope);
        return;
    }
}

/// Release one viewer and report the scope only when it became permanently
/// unviewed.
fn detachOriginScope(terminal: *Terminal) ?*RelayScope {
    const scope = attachedRelayScope(terminal) orelse return null;
    terminal.panel_scope_ctx = null;
    for (scope.viewers.items, 0..) |viewer, i| {
        if (viewer.drain != terminal.drain) continue;
        _ = scope.viewers.swapRemove(i);
        break;
    }
    if (scope.viewers.items.len != 0) return null;
    scope.viewers.deinit(std.heap.c_allocator);
    scope.viewers = .empty;
    return scope;
}

fn byId(id: u32, scope: Scope) ?*Entry {
    for (panels.items) |e| {
        if (e.panel_id != id) continue;
        if (!sameScope(e.scope, scope)) return null;
        return e;
    }
    return null;
}

/// Resolve a public operation by id while keeping direct callers confined to
/// the same typed session scope used by panel names and lists.
fn byRequestId(self: *Window, req: protocol.Request, id: u32, scope: Scope) ?*Entry {
    const entry = byId(id, scope) orelse return null;
    switch (scope) {
        .relay => return entry,
        .direct => {
            const origin = if (req.session == null) remotectl.reqPane(self, req) else null;
            return if (sameSession(entry.session, scopeOf(req, origin))) entry else null;
        },
    }
}

fn byKey(scope: Scope, session: ?[]const u8, name: []const u8) ?*Entry {
    for (panels.items) |e| {
        if (!sameScope(e.scope, scope) or !std.mem.eql(u8, e.name, name)) continue;
        // A relay's immutable exact origin is the identity; `session` is
        // mutable display/store metadata and must not orphan a panel on rename.
        if (relayScope(scope) != null or sameSession(e.session, session)) return e;
    }
    return null;
}

/// Two scopes are the same panel key. Sessionless matches ONLY
/// sessionless: it is a different shape, not a name.
fn sameSession(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// The daemon session a pane renders — the identity behind
/// `$SKETERM_SESSION`.
fn paneSession(pane: ?*Pane) ?[]const u8 {
    const p = pane orelse return null;
    const r = p.terminal.remote orelse return null;
    return r.session;
}

/// The session a request is scoped to: the explicit `session` field
/// (which is also how a pane names itself), else the resolved pane's
/// own session — and `null` when there is none, which is a scope of
/// its own rather than a name. An EMPTY explicit session is a caller
/// stating it has no session identity (`NO_SESSION_WIRE`), so it does
/// not fall through to the pane.
fn scopeOf(req: protocol.Request, pane: ?*Pane) ?[]const u8 {
    if (req.session) |s| return if (s.len == 0) null else s;
    return paneSession(pane);
}

/// The wire spelling of a scope, for a reply that echoes one.
fn wireSession(session: ?[]const u8) []const u8 {
    return session orelse NO_SESSION_WIRE;
}

fn assetOriginUsable(origin: ?*DrainHandle) bool {
    const drain = origin orelse return false;
    if (!drain.alive.load(.acquire) or !drain.panel_assets_live.load(.acquire)) return false;
    return drain.terminal != null;
}

// ─── dispatch ───────────────────────────────────────────────────

/// Handle any `panel-*` command. Called from remotectl's dispatcher;
/// always writes exactly one response line.
pub fn dispatch(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    _ = try dispatchRequest(self, req, out, allocator, null, null, null);
}

const Relay = struct {
    terminal: *Terminal,
    scope: *RelayScope,
    pane: ?*Pane,
    window: *Window,
    session: []const u8,
    request_id: u64,
    deadline_ms: i64,
};

/// Execute one daemon-forwarded panel request, deferring asset-bearing replies.
pub fn dispatchRelay(
    self: *Window,
    terminal: *Terminal,
    pane: ?*Pane,
    request_id: u64,
    request: []const u8,
) void {
    var parsed = protocol.parseRequest(self.allocator, request) catch |err| {
        const message = if (err == error.LineTooLong) "panel request is too large" else "invalid panel request JSON";
        return relayError(terminal, request_id, message);
    };
    defer parsed.deinit();
    if (std.mem.eql(u8, parsed.value.cmd, "panel-open-session")) {
        var exact = panelrpc.parseOpenSessionRequest(self.allocator, request) catch |err| {
            var buf: [160]u8 = undefined;
            const message = std.fmt.bufPrint(
                &buf,
                "invalid panel-open-session request: {s}",
                .{@errorName(err)},
            ) catch "invalid panel-open-session request";
            return relayError(terminal, request_id, message);
        };
        exact.deinit();
    }
    const remote = terminal.remote orelse return relayError(terminal, request_id, "panel presenter is not attached");
    const scope = relayScopeForTerminal(terminal) orelse
        return relayError(terminal, request_id, "panel presenter has no session scope");
    const relay = Relay{
        .terminal = terminal,
        .scope = scope,
        .pane = pane,
        .window = self,
        .session = remote.session,
        .request_id = request_id,
        .deadline_ms = @import("../util/clock.zig").nowMs() + assets.HYDRATION_DEADLINE_MS,
    };

    if (!std.mem.eql(u8, parsed.value.cmd, "panel-show") and
        !std.mem.eql(u8, parsed.value.cmd, "panel-patch") and
        !std.mem.eql(u8, parsed.value.cmd, "panel-close"))
    {
        _ = dispatchRelayNow(self, terminal, request_id, parsed.value, relay, null, null);
        return;
    }
    // Every mutation occupies one per-scope slot. Close must wait behind an
    // older hydrated show, otherwise that show can recreate the name after a
    // successful close reply.
    preparePanelOperation(self, terminal, pane, request_id, request, parsed.value, relay, remote.host != null);
}

fn relayError(terminal: *Terminal, request_id: u64, message: []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(terminal.allocator);
    protocol.writeErr(&out, terminal.allocator, message) catch return;
    terminal.replyPanelRequest(request_id, out.items);
}

fn dispatchRelayNow(
    self: *Window,
    terminal: *Terminal,
    request_id: u64,
    req: protocol.Request,
    relay: Relay,
    resolver: ?*assets.Resolver,
    report: ?[]const assets.Report,
) DispatchOutcome {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    const outcome = dispatchRequest(self, req, &out, self.allocator, relay, resolver, report) catch {
        out.clearRetainingCapacity();
        protocol.writeErr(&out, self.allocator, "panel dispatch failed") catch return .complete;
        terminal.replyPanelRequest(request_id, out.items);
        return .complete;
    };
    if (outcome == .pending) return .pending;
    terminal.replyPanelRequest(request_id, out.items);
    return .complete;
}

const DispatchOutcome = enum { complete, pending };

fn dispatchRequest(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    relay: ?Relay,
    resolver: ?*assets.Resolver,
    report: ?[]const assets.Report,
) !DispatchOutcome {
    const eql = std.mem.eql;
    if (eql(u8, req.cmd, "panel-show")) {
        return panelShow(self, req, out, allocator, relay, resolver, report);
    } else if (eql(u8, req.cmd, "panel-patch")) {
        try panelPatch(self, req, out, allocator, if (relay) |r| .{ .relay = r.scope } else .direct, resolver, report);
    } else if (eql(u8, req.cmd, "panel-get")) {
        try panelGet(self, req, out, allocator, if (relay) |r| .{ .relay = r.scope } else .direct);
    } else if (eql(u8, req.cmd, "panel-events")) {
        try panelEvents(self, req, out, allocator, if (relay) |r| .{ .relay = r.scope } else .direct, false);
    } else if (eql(u8, req.cmd, "panel-events-reliable")) {
        try panelEvents(self, req, out, allocator, if (relay) |r| .{ .relay = r.scope } else .direct, true);
    } else if (eql(u8, req.cmd, "panel-list")) {
        try panelList(self, req, out, allocator, relay);
    } else if (eql(u8, req.cmd, "panel-close")) {
        try panelClose(self, req, out, allocator, if (relay) |r| .{ .relay = r.scope } else .direct);
    } else if (eql(u8, req.cmd, "panel-open-session")) {
        return panelOpenSession(out, allocator, req, relay);
    } else {
        try protocol.writeErr(out, allocator, "unknown panel command");
    }
    return .complete;
}

fn reportFailureCount(report: []const assets.Report) usize {
    var count: usize = 0;
    for (report) |item| if (!item.ok) {
        count += 1;
    };
    return count;
}

fn preparePanelOperation(
    self: *Window,
    terminal: *Terminal,
    pane: ?*Pane,
    request_id: u64,
    request: []const u8,
    req: protocol.Request,
    relay: Relay,
    hydrate_remote: bool,
) void {
    if (hydrations.items.len + queued_panel_operations.items.len + panel_tab_jobs.items.len +
        panel_open_session_jobs.items.len >= MAX_PENDING_PANEL_OPERATIONS)
        return relayError(terminal, request_id, "too many panel operations are pending");
    var origin_pending: usize = 0;
    for (hydrations.items) |pending| if (pending.relay_scope == relay.scope) {
        origin_pending += 1;
    };
    for (queued_panel_operations.items) |pending| if (pending.scope == relay.scope) {
        origin_pending += 1;
    };
    for (panel_tab_jobs.items) |job| if (job.scope == relay.scope) {
        origin_pending += 1;
    };
    if (origin_pending >= MAX_PENDING_PER_ORIGIN)
        return relayError(terminal, request_id, "too many panel operations are pending for this session");

    const deadline_ms = @import("../util/clock.zig").nowMs() + assets.HYDRATION_DEADLINE_MS;
    if (origin_pending == 0) {
        preparePanelOperationNow(self, terminal, pane, request_id, request, req, relay, deadline_ms, hydrate_remote);
        if (!hasActivePanelWork(relay.scope)) startNextQueuedPanelOperation(relay.scope);
        return;
    }

    const queued = self.allocator.create(QueuedPanelOperation) catch
        return relayError(terminal, request_id, "out of memory queueing the panel operation");
    const request_copy = self.allocator.dupe(u8, request) catch {
        self.allocator.destroy(queued);
        return relayError(terminal, request_id, "out of memory queueing the panel operation");
    };
    queued.* = .{
        .allocator = self.allocator,
        .scope = relay.scope,
        .origin = terminal.drain,
        .window = self,
        .pane = pane,
        .request_id = request_id,
        .request = request_copy,
        .deadline_ms = deadline_ms,
    };
    queued_panel_operations.append(self.allocator, queued) catch {
        queued.deinit();
        return relayError(terminal, request_id, "out of memory queueing the panel operation");
    };
}

fn preparePanelOperationNow(
    self: *Window,
    terminal: *Terminal,
    pane: ?*Pane,
    request_id: u64,
    request: []const u8,
    req: protocol.Request,
    relay: Relay,
    deadline_ms: i64,
    hydrate_remote: bool,
) void {
    if (std.mem.eql(u8, req.cmd, "panel-close")) {
        _ = dispatchRelayNow(self, terminal, request_id, req, relay, null, null);
        return;
    }
    var diag = Doc.Diag{};
    var candidate: Doc.Document = undefined;
    var have_candidate = false;
    defer if (have_candidate) candidate.deinit();
    var current_view: ?*PanelView = null;
    var changed_paths: ?assets.Paths = null;
    defer if (changed_paths) |*paths| paths.deinit();

    if (std.mem.eql(u8, req.cmd, "panel-show")) {
        const document = req.document orelse return relayError(terminal, request_id, "panel-show requires a document (JSON string)");
        candidate = Doc.Document.parse(self.allocator, document, &diag) catch |err| {
            const message = if (diag.len > 0) diag.msg() else @errorName(err);
            return relayError(terminal, request_id, message);
        };
        have_candidate = true;
    } else {
        const id = req.panel_id orelse return relayError(terminal, request_id, "panel-patch requires panel_id");
        const patch = req.patch orelse return relayError(terminal, request_id, "panel-patch requires patch (JSON array of ops)");
        const entry = byId(id, .{ .relay = relay.scope }) orelse return relayError(terminal, request_id, "no such panel");
        current_view = entry.view;
        const current = (entry.view.documentJson(self.allocator) catch null) orelse
            return relayError(terminal, request_id, "panel has no document");
        defer self.allocator.free(current);
        candidate = Doc.Document.parse(self.allocator, current, &diag) catch |err| {
            const message = if (diag.len > 0) diag.msg() else @errorName(err);
            return relayError(terminal, request_id, message);
        };
        have_candidate = true;
        var applied = candidate.applyPatch(patch, &diag) catch |err| {
            const message = if (diag.len > 0) diag.msg() else @errorName(err);
            return relayError(terminal, request_id, message);
        };
        changed_paths = assets.collectComponentPaths(self.allocator, &candidate, applied.set) catch |err| {
            applied.deinit();
            const message = if (err == error.TooMany)
                "panel patch resets more than 64 unique image assets"
            else
                "could not allocate the changed panel asset list";
            return relayError(terminal, request_id, message);
        };
        applied.deinit();
    }

    var paths = assets.collectPaths(self.allocator, &candidate) catch |err| {
        const message = if (err == error.TooMany)
            "panel operation references more than 64 unique image assets"
        else
            "could not allocate the panel asset list";
        return relayError(terminal, request_id, message);
    };
    defer paths.deinit();

    const resolver_cache = if (current_view) |view| view.assetCache() orelse panel_asset_cache else panel_asset_cache;
    var resolver = assets.Resolver.init(self.allocator, resolver_cache);
    defer resolver.deinit();
    const plan = planHydrationFlags(
        self.allocator,
        &paths,
        if (changed_paths) |*changed| changed else null,
        current_view,
        &resolver,
    ) catch return relayError(terminal, request_id, "out of memory preparing panel assets");
    defer self.allocator.free(plan.flags);
    if (plan.count == 0) {
        // This also handles a zero-image document: replacing with the explicit
        // empty resolver releases only mappings absent from the candidate.
        _ = dispatchRelayNow(self, terminal, request_id, req, relay, &resolver, &.{});
        return;
    }
    startHydrationOperation(
        self,
        terminal.drain,
        pane,
        relay.scope,
        0,
        request_id,
        request,
        if (hydrate_remote) .remote else .local,
        &resolver,
        &paths,
        plan.flags,
        plan.count,
        deadline_ms,
    ) catch return relayError(terminal, request_id, "out of memory preparing panel assets");
}

const HydrationPlan = struct {
    flags: []bool,
    count: usize,
};

/// Decide which collected paths must hydrate, copying every still-valid
/// live mapping into `resolver` for the rest. `view` must be non-null
/// whenever `changed_paths` is (only a patch has a current view to copy
/// from). Caller frees `flags`.
fn planHydrationFlags(
    allocator: std.mem.Allocator,
    paths: *const assets.Paths,
    changed_paths: ?*const assets.Paths,
    view: ?*const PanelView,
    resolver: *assets.Resolver,
) !HydrationPlan {
    const flags = try allocator.alloc(bool, paths.items.len);
    errdefer allocator.free(flags);
    var count: usize = 0;
    for (paths.items, 0..) |path, i| {
        var hydrate = changed_paths == null or assets.containsPath(changed_paths.?, path);
        if (!hydrate) hydrate = !(try view.?.copyAssetResolution(resolver, path));
        flags[i] = hydrate;
        if (hydrate) count += 1;
    }
    return .{ .flags = flags, .count = count };
}

/// Build, register and start one Hydration for every hydrate-flagged path.
/// THE construction path for both relay and direct operations, so the id
/// wraparound and the unwind order cannot diverge between them. Consumes
/// `resolver`'s mappings (success or failure); the caller's deferred deinit
/// then frees an empty resolver.
fn startHydrationOperation(
    window: *Window,
    origin: *DrainHandle,
    pane: ?*Pane,
    relay_scope: ?*RelayScope,
    direct_panel_id: u32,
    request_id: u64,
    request: []const u8,
    read_source: HydrationReadSource,
    resolver: *assets.Resolver,
    paths: *const assets.Paths,
    flags: []const bool,
    count: usize,
    deadline_ms: i64,
) error{OutOfMemory}!void {
    const allocator = window.allocator;
    const pending = try allocator.create(Hydration);
    errdefer allocator.destroy(pending);
    const request_copy = try allocator.dupe(u8, request);
    errdefer allocator.free(request_copy);
    const asset_list = try allocator.alloc(HydrationAsset, count);
    errdefer allocator.free(asset_list);
    pending.* = .{
        .allocator = allocator,
        .id = next_hydration_id,
        .relay_scope = relay_scope,
        .origin = origin,
        .window = window,
        .pane = pane,
        .request_id = request_id,
        .request = request_copy,
        .assets = asset_list,
        .read_source = read_source,
        .resolver = assets.Resolver.init(allocator, resolver.cache),
        .direct_panel_id = direct_panel_id,
        .deadline_ms = deadline_ms,
    };
    pending.resolver.replaceFrom(resolver);
    next_hydration_id +%= 1;
    if (next_hydration_id == 0) next_hydration_id = 1;
    var initialized: usize = 0;
    errdefer {
        for (asset_list[0..initialized]) |asset| allocator.free(asset.logical);
        pending.resolver.deinit();
    }
    for (paths.items, 0..) |path, i| {
        if (!flags[i]) continue;
        asset_list[initialized] = .{
            .pending = pending,
            .logical = try allocator.dupe(u8, path),
            .bytes_allocator = allocator,
        };
        initialized += 1;
    }
    try hydrations.append(allocator, pending);
    if (hydration_timer == 0)
        hydration_timer = c.g_timeout_add(100, @ptrCast(&hydrationTick), null);
    pumpHydrations();
}

fn prepareDirectLocalImages(
    self: *Window,
    origin: *DrainHandle,
    entry: *Entry,
    document: []const u8,
    changed_paths: ?*const assets.Paths,
) !void {
    if (hydrations.items.len + queued_panel_operations.items.len + panel_tab_jobs.items.len +
        panel_open_session_jobs.items.len >= MAX_PENDING_PANEL_OPERATIONS)
        return error.Busy;
    var parsed = try Doc.Document.parse(self.allocator, document, null);
    defer parsed.deinit();
    var paths = try assets.collectPaths(self.allocator, &parsed);
    defer paths.deinit();
    var resolver = assets.Resolver.init(self.allocator, entry.view.assetCache() orelse panel_asset_cache);
    defer resolver.deinit();
    const plan = try planHydrationFlags(self.allocator, &paths, changed_paths, entry.view, &resolver);
    defer self.allocator.free(plan.flags);
    if (plan.count == 0) {
        entry.view.installAssetResolver(&resolver);
        return;
    }
    try startHydrationOperation(
        self,
        origin,
        null,
        null,
        entry.panel_id,
        0,
        "",
        .local,
        &resolver,
        &paths,
        plan.flags,
        plan.count,
        @import("../util/clock.zig").nowMs() + assets.HYDRATION_DEADLINE_MS,
    );
}

fn isTerminalAssetState(state: HydrationAssetState) bool {
    return state == .success or state == .failed;
}

fn sameHydrationLane(a: *const Hydration, b: *const Hydration) bool {
    if (a.relay_scope != null or b.relay_scope != null)
        return a.relay_scope != null and a.relay_scope == b.relay_scope;
    return a.origin == b.origin;
}

fn firstForOrigin(pending: *Hydration) bool {
    for (hydrations.items) |candidate| {
        if (candidate == pending) return true;
        if (sameHydrationLane(candidate, pending)) return false;
    }
    return false;
}

fn hasActivePanelWork(scope: *RelayScope) bool {
    for (hydrations.items) |pending| if (pending.relay_scope == scope) return true;
    for (panel_tab_jobs.items) |job| if (job.scope == scope) return true;
    return false;
}

fn currentHydrationWindow(fallback: *Window, pane: ?*Pane) *Window {
    return if (pane) |p| remotectl.ownerWindow(fallback, p) else fallback;
}

/// Rebind work captured by a tabless AppSession after its Terminal becomes a
/// pane, before the AppSession's source Window can be destroyed.
pub fn adoptTerminalOwner(terminal: *Terminal, pane: *Pane, owner: *Window) void {
    const drain = terminal.drain;
    for (hydrations.items) |pending| {
        if (pending.origin != drain) continue;
        pending.window = owner;
        pending.pane = pane;
    }
    for (queued_panel_operations.items) |pending| {
        if (pending.origin != drain) continue;
        pending.window = owner;
        pending.pane = pane;
    }
    for (panel_tab_jobs.items) |job| {
        if (job.origin != drain) continue;
        job.window = owner;
        job.pane = pane;
    }
    for (panel_open_session_jobs.items) |job| {
        if (job.origin != drain) continue;
        job.window = owner;
        job.pane = pane;
    }
}

/// Start the oldest queued request for this origin after the prior request has
/// committed. Requests without assets may complete synchronously, so keep
/// draining until one starts asynchronous work or the origin's queue is empty.
fn startNextQueuedPanelOperation(scope: *RelayScope) void {
    while (!hasActivePanelWork(scope)) {
        var index: ?usize = null;
        for (queued_panel_operations.items, 0..) |queued, i| if (queued.scope == scope) {
            index = i;
            break;
        };
        const i = index orelse return;
        const queued = queued_panel_operations.orderedRemove(i);
        const origin = queued.origin;
        const terminal = if (origin.alive.load(.acquire)) origin.terminal else null;
        const term = terminal orelse {
            queued.deinit();
            continue;
        };
        const remote = term.remote orelse {
            queued.deinit();
            continue;
        };
        if (!remote.canSend()) {
            queued.deinit();
            continue;
        }
        if (@import("../util/clock.zig").nowMs() >= queued.deadline_ms) {
            relayError(term, queued.request_id, "panel operation expired while waiting for an earlier operation");
            queued.deinit();
            continue;
        }
        var parsed = protocol.parseRequest(queued.allocator, queued.request) catch {
            relayError(term, queued.request_id, "queued panel request became invalid");
            queued.deinit();
            continue;
        };
        const host = currentHydrationWindow(queued.window, queued.pane);
        const relay = Relay{
            .terminal = term,
            .scope = scope,
            .pane = queued.pane,
            .window = host,
            .session = remote.session,
            .request_id = queued.request_id,
            .deadline_ms = queued.deadline_ms,
        };
        preparePanelOperationNow(
            host,
            term,
            queued.pane,
            queued.request_id,
            queued.request,
            parsed.value,
            relay,
            queued.deadline_ms,
            remote.host != null,
        );
        parsed.deinit();
        queued.deinit();
    }
}

fn globalWorkCount() usize {
    var count: usize = 0;
    for (hydrations.items) |pending| for (pending.assets) |asset| switch (asset.state) {
        .reading, .cache_wait, .caching => count += 1,
        else => {},
    };
    return count;
}

fn activeReadCount(pending: *const Hydration) usize {
    var count: usize = 0;
    for (pending.assets) |asset| if (asset.state == .reading) {
        count += 1;
    };
    return count;
}

const ReadBudget = union(enum) {
    start: usize,
    wait,
    exhausted,
};

/// Reserve full per-file capacity for every active read; a later read waits
/// instead of receiving an artificially smaller cap that could reject it.
fn nextReadBudget(committed: u64, active_reads: usize) ReadBudget {
    if (committed >= assets.MAX_OPERATION_BYTES) return .exhausted;
    const remaining = assets.MAX_OPERATION_BYTES - committed;
    const active_reserve = @as(u64, @intCast(active_reads)) * assets.MAX_ASSET_BYTES;
    if (active_reads > 0 and remaining < active_reserve + assets.MAX_ASSET_BYTES)
        return .wait;
    if (remaining <= active_reserve) return .wait;
    return .{ .start = @intCast(@min(
        @as(u64, assets.MAX_ASSET_BYTES),
        remaining - active_reserve,
    )) };
}

fn pumpHydrations() void {
    startWaitingCacheJobs();
    var work = globalWorkCount();
    var pending_index: usize = 0;
    while (pending_index < hydrations.items.len) {
        const pending = hydrations.items[pending_index];
        if (!firstForOrigin(pending)) {
            pending_index += 1;
            continue;
        }
        const terminal = if (pending.origin.alive.load(.acquire)) pending.origin.terminal else null;
        const term = terminal orelse {
            pending_index += 1;
            continue;
        };
        if (pending.direct_panel_id == 0) {
            const remote = term.remote orelse {
                pending_index += 1;
                continue;
            };
            if (!remote.canSend()) {
                pending_index += 1;
                continue;
            }
        }
        for (pending.assets, 0..) |*asset, asset_index| {
            if (work >= assets.MAX_CONCURRENT_READS or asset.state != .queued) continue;
            const read_budget = switch (nextReadBudget(pending.total_bytes, activeReadCount(pending))) {
                .start => |budget| budget,
                .wait => continue,
                .exhausted => {
                    failHydrationAsset(asset, "panel operation exceeds the total hydrated-byte limit");
                    continue;
                },
            };
            if (pending.read_source == .remote) {
                const token = term.beginRemoteFileRead(
                    asset.logical,
                    read_budget,
                    pending.deadline_ms - @import("../util/clock.zig").nowMs(),
                    @ptrCast(asset),
                    onHydrationRead,
                ) catch |err| {
                    if (err == error.Busy) continue;
                    failHydrationAsset(asset, "could not start the remote asset read");
                    continue;
                };
                asset.state = .reading;
                asset.read_token = token;
                asset.read_limit = read_budget;
            } else {
                if (active_local_read_jobs >= assets.MAX_CONCURRENT_READS) continue;
                startLocalRead(asset, asset_index, read_budget) catch {
                    failHydrationAsset(asset, "could not start the local asset worker");
                    continue;
                };
            }
            work += 1;
        }
        maybeCompleteHydration(pending);
        if (pending_index < hydrations.items.len and hydrations.items[pending_index] == pending)
            pending_index += 1;
    }
}

fn onHydrationRead(
    ctx: ?*anyopaque,
    terminal: *Terminal,
    token: u32,
    result: Terminal.RemoteFileResult,
) void {
    const asset: *HydrationAsset = @ptrCast(@alignCast(ctx.?));
    if (asset.state != .reading or asset.read_token != token or asset.pending.origin.terminal != terminal) {
        if (result == .success) terminal.allocator.free(result.success.bytes);
        return;
    }
    asset.read_token = 0;
    const read_limit = asset.read_limit;
    asset.read_limit = 0;
    switch (result) {
        .failure => |message| failHydrationAsset(
            asset,
            if (read_limit < assets.MAX_ASSET_BYTES and
                std.mem.eql(u8, message, "remote asset exceeds the per-file byte limit"))
                "panel operation exceeds the total hydrated-byte limit"
            else
                message,
        ),
        .success => |success| {
            if (asset.pending.total_bytes +| success.size > assets.MAX_OPERATION_BYTES) {
                terminal.allocator.free(success.bytes);
                failHydrationAsset(asset, "panel operation exceeds the total hydrated-byte limit");
            } else {
                asset.pending.total_bytes += success.size;
                asset.bytes = success.size;
                asset.bytes_data = success.bytes;
                asset.bytes_allocator = terminal.allocator;
                asset.state = .cache_wait;
            }
        },
    }
    pumpHydrations();
}

fn failHydrationAsset(asset: *HydrationAsset, message: []const u8) void {
    if (asset.bytes_data) |bytes| {
        asset.bytes_allocator.free(bytes);
        asset.bytes_data = null;
    }
    if (asset.failure) |old| asset.pending.allocator.free(old);
    asset.failure = asset.pending.allocator.dupe(u8, message) catch null;
    asset.state = .failed;
    std.debug.print("sketerm: panel asset '{s}': {s}\n", .{ asset.logical, message });
}

const LocalReadError = error{ TooBig, Deadline, NotRegular, IoFailed, OutOfMemory, PathTooLong };

fn startLocalRead(asset: *HydrationAsset, asset_index: usize, limit: usize) !void {
    const allocator = std.heap.c_allocator;
    const job = try allocator.create(LocalReadJob);
    errdefer allocator.destroy(job);
    const path = try allocator.dupe(u8, asset.logical);
    errdefer allocator.free(path);
    job.* = .{
        .drain = asset.pending.origin,
        .pending_id = asset.pending.id,
        .asset_index = asset_index,
        .path = path,
        .limit = limit,
        .deadline_ms = asset.pending.deadline_ms,
    };
    asset.state = .reading;
    asset.read_limit = limit;
    active_local_read_jobs += 1;
    const thread = std.Thread.spawn(.{}, localReadJobMain, .{job}) catch |err| {
        active_local_read_jobs -= 1;
        asset.state = .queued;
        asset.read_limit = 0;
        job.deinit();
        return err;
    };
    thread.detach();
}

fn localReadJobMain(job: *LocalReadJob) void {
    job.bytes = readLocalAsset(std.heap.c_allocator, job.path, job.limit, job.deadline_ms) catch |err| blk: {
        job.failure = switch (err) {
            error.TooBig => "local asset exceeds the per-file byte limit",
            error.Deadline => "panel asset hydration deadline exceeded",
            error.NotRegular => "local asset is not a regular file",
            error.PathTooLong => "local asset path is too long",
            error.OutOfMemory => "out of memory reading the local asset",
            error.IoFailed => "could not read the local asset",
        };
        break :blk null;
    };
    job.ready.store(true, .release);
    _ = c.g_idle_add(@ptrCast(&localReadJobDone), @ptrCast(job));
}

fn readLocalAsset(
    allocator: std.mem.Allocator,
    path: []const u8,
    limit: usize,
    deadline_ms: i64,
) LocalReadError![]u8 {
    if (@import("../util/clock.zig").nowMs() >= deadline_ms) return error.Deadline;
    var path_buf: [4096]u8 = undefined;
    const path_z = @import("../util/pathz.zig").pathZ(&path_buf, path) catch return error.PathTooLong;
    const fd = c.open(path_z, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return error.IoFailed;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return error.IoFailed;
    if ((st.st_mode & c.S_IFMT) != c.S_IFREG) return error.NotRegular;
    if (st.st_size < 0 or @as(u64, @intCast(st.st_size)) > limit) return error.TooBig;

    const buffer = allocator.alloc(u8, limit + 1) catch return error.OutOfMemory;
    errdefer allocator.free(buffer);
    var len: usize = 0;
    while (true) {
        if (@import("../util/clock.zig").nowMs() >= deadline_ms) return error.Deadline;
        if (len == buffer.len) return error.TooBig;
        const n = c.read(fd, buffer.ptr + len, buffer.len - len);
        if (n > 0) {
            len += @intCast(n);
            if (len > limit) return error.TooBig;
            continue;
        }
        if (n == 0) break;
        if (std.posix.errno(n) == .INTR) continue;
        return error.IoFailed;
    }
    return allocator.realloc(buffer, len) catch return error.OutOfMemory;
}

fn localReadJobDone(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(LocalReadJob, user);
    if (!job.ready.load(.acquire)) return 1;
    if (active_local_read_jobs > 0) active_local_read_jobs -= 1;
    if (findHydration(job.pending_id)) |pending| {
        if (job.asset_index < pending.assets.len) {
            const asset = &pending.assets[job.asset_index];
            if (asset.state == .reading and pending.read_source == .local) {
                asset.read_limit = 0;
                if (!job.drain.alive.load(.acquire) or job.drain.terminal == null) {
                    failHydrationAsset(asset, "panel origin closed during local asset hydration");
                } else if (job.bytes) |bytes| {
                    if (pending.total_bytes +| bytes.len > assets.MAX_OPERATION_BYTES) {
                        failHydrationAsset(asset, "panel operation exceeds the total hydrated-byte limit");
                    } else {
                        pending.total_bytes += bytes.len;
                        asset.bytes = bytes.len;
                        asset.bytes_data = bytes;
                        asset.bytes_allocator = std.heap.c_allocator;
                        asset.state = .cache_wait;
                        job.bytes = null;
                    }
                } else {
                    failHydrationAsset(asset, job.failure orelse "local asset read failed");
                }
            }
        }
    }
    job.deinit();
    pumpHydrations();
    return 0;
}

fn startWaitingCacheJobs() void {
    if (active_cache_jobs >= assets.MAX_CONCURRENT_CACHE_WRITES) return;
    const cache = panel_asset_cache orelse {
        if (cache_init_active) return;
        for (hydrations.items) |pending| {
            if (!pending.origin.alive.load(.acquire) or pending.origin.terminal == null) continue;
            for (pending.assets) |asset| if (asset.state == .cache_wait) {
                startCacheInit(pending.origin) catch {
                    failCacheWaitingAssets("could not start the panel asset cache worker");
                };
                return;
            };
        }
        return;
    };
    for (hydrations.items) |pending| {
        if (!firstForOrigin(pending)) continue;
        for (pending.assets, 0..) |*asset, i| {
            if (active_cache_jobs >= assets.MAX_CONCURRENT_CACHE_WRITES) return;
            if (asset.state != .cache_wait) continue;
            const bytes = asset.bytes_data orelse {
                failHydrationAsset(asset, "remote asset bytes were lost before caching");
                continue;
            };
            const allocator = std.heap.c_allocator;
            const job = allocator.create(CacheJob) catch {
                failHydrationAsset(asset, "out of memory starting the panel asset cache write");
                continue;
            };
            const root = allocator.dupe(u8, cache.root) catch {
                allocator.destroy(job);
                failHydrationAsset(asset, "out of memory starting the panel asset cache write");
                continue;
            };
            const protected = protectedCacheHashes(cache, allocator) catch {
                allocator.free(root);
                allocator.destroy(job);
                failHydrationAsset(asset, "out of memory protecting active panel cache entries");
                continue;
            };
            job.* = .{
                .drain = pending.origin,
                .pending_id = pending.id,
                .asset_index = i,
                .nonce = (pending.id << 8) ^ i,
                .root = root,
                .bytes = bytes,
                .bytes_allocator = asset.bytes_allocator,
                .protected = protected,
            };
            asset.bytes_data = null;
            asset.state = .caching;
            active_cache_jobs += 1;
            const thread = std.Thread.spawn(.{}, cacheJobMain, .{job}) catch {
                active_cache_jobs -= 1;
                asset.bytes_data = bytes;
                asset.state = .cache_wait;
                job.owns_bytes = false;
                job.deinit();
                failHydrationAsset(asset, "could not start the panel asset cache worker");
                continue;
            };
            thread.detach();
        }
    }
}

fn startCacheInit(drain: *DrainHandle) !void {
    const allocator = std.heap.c_allocator;
    const job = try allocator.create(CacheInitJob);
    job.* = .{
        .drain = drain,
    };
    cache_init_active = true;
    const thread = std.Thread.spawn(.{}, cacheInitJobMain, .{job}) catch |err| {
        cache_init_active = false;
        job.deinit();
        return err;
    };
    thread.detach();
}

fn cacheInitJobMain(job: *CacheInitJob) void {
    runCacheInitJob(job, initPanelAssetCache);
    _ = c.g_idle_add(@ptrCast(&cacheInitJobDone), @ptrCast(job));
}

/// Seam kept for the worker-protocol test only: it must init its cache at a
/// throwaway root, and `assets.Cache.init` would claim (and prune) the user's
/// real XDG cache namespace. Production always passes `initPanelAssetCache`.
const CacheInitFn = *const fn (std.mem.Allocator) anyerror!assets.Cache;

fn initPanelAssetCache(allocator: std.mem.Allocator) !assets.Cache {
    return assets.Cache.init(allocator);
}

fn runCacheInitJob(job: *CacheInitJob, init_fn: CacheInitFn) void {
    if (job.test_delay_ms > 0) _ = c.usleep(job.test_delay_ms * 1000);
    const allocator = std.heap.c_allocator;
    const cache: ?*assets.Cache = allocator.create(assets.Cache) catch null;
    if (cache) |value| {
        value.* = init_fn(allocator) catch |err| {
            allocator.destroy(value);
            job.failure = @errorName(err);
            job.ready.store(true, .release);
            return;
        };
        job.cache = value;
    } else {
        job.failure = "out of memory initializing the panel asset cache";
    }
    job.ready.store(true, .release);
}

fn cacheInitJobDone(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(CacheInitJob, user);
    if (!job.ready.load(.acquire)) return 1;
    cache_init_active = false;
    const origin_live = job.drain.alive.load(.acquire) and job.drain.terminal != null;
    if (origin_live and panel_asset_cache == null) {
        if (job.cache) |cache| {
            panel_asset_cache = cache;
            job.cache = null;
        } else {
            failCacheWaitingAssets(job.failure orelse "the GUI could not initialize its panel asset cache");
        }
    }
    job.deinit();
    pumpHydrations();
    return 0;
}

fn failCacheWaitingAssets(message: []const u8) void {
    for (hydrations.items) |pending| for (pending.assets) |*asset| {
        if (asset.state == .cache_wait) failHydrationAsset(asset, message);
    };
}

fn protectedCacheHashes(cache: *assets.Cache, allocator: std.mem.Allocator) ![][64]u8 {
    var hashes: std.ArrayList([64]u8) = .empty;
    errdefer hashes.deinit(allocator);
    const leased = try cache.protected(allocator);
    defer allocator.free(leased);
    try hashes.appendSlice(allocator, leased);
    for (hydrations.items) |pending| for (pending.assets) |asset| {
        const hash = asset.hash orelse continue;
        var exists = false;
        for (hashes.items) |active| if (std.mem.eql(u8, &active, &hash)) {
            exists = true;
            break;
        };
        if (!exists) try hashes.append(allocator, hash);
    };
    return hashes.toOwnedSlice(allocator);
}

fn runCacheJob(job: *CacheJob) void {
    while (cache_store_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null)
        _ = c.usleep(1_000);
    defer cache_store_lock.store(false, .release);
    job.stored = assets.store(
        std.heap.c_allocator,
        job.root,
        job.bytes,
        job.protected,
        job.nonce,
    ) catch |err| blk: {
        job.failure = switch (err) {
            error.TooBig => "remote asset exceeds the per-file byte limit",
            error.Capacity => "panel asset cache is full and all reclaimable space is in use",
            error.IoFailed => "could not atomically write the panel asset cache",
            error.OutOfMemory => "out of memory writing the panel asset cache",
        };
        break :blk null;
    };
    if (job.stored) |*stored| {
        job.decode_started.store(true, .release);
        if (job.test_delay_ms > 0) _ = c.usleep(job.test_delay_ms * 1000);
        const decoded = decodeCachedImage(stored.path) catch |err| blk: {
            job.failure = switch (err) {
                error.PathTooLong => "cached panel asset path is too long",
                error.Unrecognized => "file is not a recognized image",
                error.Dimensions => "image dimensions exceed the 8192px/32MP panel limit",
                error.ProcessBudget => assets.PROCESS_PREPARED_BUDGET_ERROR,
                error.DecodeRejected => "image decoder rejected the hydrated file",
            };
            break :blk null;
        };
        if (decoded) |image| {
            job.prepared = image.pixbuf;
            job.prepared_reservation = image.reservation;
        }
    }
    job.ready.store(true, .release);
}

fn cacheJobMain(job: *CacheJob) void {
    runCacheJob(job);
    _ = c.g_idle_add(@ptrCast(&cacheJobDone), @ptrCast(job));
}

fn cacheJobDone(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(CacheJob, user);
    if (!job.ready.load(.acquire)) return 1;
    if (active_cache_jobs > 0) active_cache_jobs -= 1;
    const pending = findHydration(job.pending_id);
    if (pending) |operation| {
        if (job.asset_index < operation.assets.len) {
            const asset = &operation.assets[job.asset_index];
            if (asset.state == .caching) {
                if (!job.drain.alive.load(.acquire) or job.drain.terminal == null) {
                    failHydrationAsset(asset, "panel origin closed during asset hydration");
                } else if (job.stored) |*stored| {
                    if (job.prepared == null) {
                        failHydrationAsset(asset, job.failure orelse "image decoder rejected the hydrated file");
                    } else {
                        const prepared = job.prepared.?;
                        const lease = assets.PreparedLease.adoptReserved(
                            std.heap.c_allocator,
                            @ptrCast(prepared),
                            &job.prepared_reservation.?,
                        ) catch {
                            failHydrationAsset(asset, "out of memory retaining the decoded panel image");
                            job.deinit();
                            pumpHydrations();
                            return 0;
                        };
                        asset.cache_path = stored.path;
                        asset.hash = stored.hash;
                        asset.bytes = stored.bytes;
                        asset.prepared_lease = lease;
                        asset.state = .success;
                        stored.path = &.{};
                        job.stored = null;
                        job.prepared = null;
                        job.prepared_reservation = null;
                    }
                } else {
                    failHydrationAsset(asset, job.failure orelse "panel asset cache write failed");
                }
            }
        }
    }
    job.deinit();
    pumpHydrations();
    return 0;
}

const DecodeImageError = error{ PathTooLong, Unrecognized, Dimensions, ProcessBudget, DecodeRejected };

const DecodedImage = struct {
    pixbuf: *c.GdkPixbuf,
    reservation: assets.ProcessPreparedReservation,
};

fn decodeCachedImage(path: []const u8) DecodeImageError!DecodedImage {
    var path_buf: [4096]u8 = undefined;
    const path_z = @import("../util/pathz.zig").pathZ(&path_buf, path) catch
        return error.PathTooLong;
    var width: c_int = 0;
    var height: c_int = 0;
    if (c.gdk_pixbuf_get_file_info(path_z, &width, &height) == null or width <= 0 or height <= 0)
        return error.Unrecognized;
    const header_info = try assets.preparedInfoForDimensions(@intCast(width), @intCast(height));
    var reservation = assets.ProcessPreparedReservation.reserve(header_info) catch
        return error.ProcessBudget;
    var reservation_owned = true;
    defer if (reservation_owned) reservation.release();
    const pixbuf = c.gdk_pixbuf_new_from_file(path_z, null) orelse
        return error.DecodeRejected;
    const decoded_width = c.gdk_pixbuf_get_width(pixbuf);
    const decoded_height = c.gdk_pixbuf_get_height(pixbuf);
    if (decoded_width <= 0 or decoded_height <= 0) {
        c.g_object_unref(@ptrCast(pixbuf));
        return error.Dimensions;
    }
    const decoded_info = assets.preparedInfoForDimensions(@intCast(decoded_width), @intCast(decoded_height)) catch {
        c.g_object_unref(@ptrCast(pixbuf));
        return error.Dimensions;
    };
    const rowstride = c.gdk_pixbuf_get_rowstride(pixbuf);
    if (rowstride <= 0) {
        c.g_object_unref(@ptrCast(pixbuf));
        return error.DecodeRejected;
    }
    const actual_bytes = std.math.mul(u64, @intCast(rowstride), @intCast(decoded_height)) catch {
        c.g_object_unref(@ptrCast(pixbuf));
        return error.Dimensions;
    };
    const info = assets.PreparedInfo{ .pixels = decoded_info.pixels, .bytes = actual_bytes };
    reservation.reconcile(info) catch {
        c.g_object_unref(@ptrCast(pixbuf));
        return error.ProcessBudget;
    };
    reservation_owned = false;
    return .{ .pixbuf = pixbuf, .reservation = reservation };
}

fn findHydration(id: u64) ?*Hydration {
    for (hydrations.items) |pending| if (pending.id == id) return pending;
    return null;
}

fn maybeCompleteHydration(pending: *Hydration) void {
    for (pending.assets) |asset| if (!isTerminalAssetState(asset.state)) return;
    completeHydration(pending);
}

fn completeHydration(pending: *Hydration) void {
    // From this point the callback owns `pending` privately. Dispatch and
    // reply can synchronously lose the transport, whose cancellation hook
    // walks the global lists; it must never find and free this object again.
    if (!unlinkHydration(pending)) return;
    const scope = pending.relay_scope;
    defer {
        pending.deinit();
        if (scope) |relay_scope| {
            startNextQueuedPanelOperation(relay_scope);
            releaseRelayScopeIfIdle(relay_scope);
        }
    }

    const terminal = if (pending.origin.alive.load(.acquire)) pending.origin.terminal else null;
    const term = terminal orelse return;
    if (pending.resolver.cache == null) pending.resolver.cache = panel_asset_cache;
    for (pending.assets) |asset| {
        if (asset.state == .success and asset.cache_path != null and asset.hash != null) {
            pending.resolver.addSuccessLease(
                asset.logical,
                asset.cache_path.?,
                asset.hash.?,
                asset.bytes,
                asset.prepared_lease.?,
            ) catch {
                relayError(term, pending.request_id, "out of memory committing panel asset mappings");
                return;
            };
        } else {
            pending.resolver.addFailure(asset.logical, asset.failure orelse "panel asset hydration failed") catch {
                relayError(term, pending.request_id, "out of memory committing panel asset failures");
                return;
            };
        }
    }
    if (pending.direct_panel_id != 0) {
        const entry = byId(pending.direct_panel_id, .direct) orelse return;
        var updates = assets.Resolver.init(pending.allocator, pending.resolver.cache);
        defer updates.deinit();
        for (pending.assets) |asset| {
            if (laterDirectRefreshExists(pending, asset.logical)) continue;
            _ = updates.copyFrom(&pending.resolver, asset.logical) catch return;
        }
        entry.view.mergeAssetResolver(&updates) catch {};
        return;
    }
    const report = hydrationReports(pending) catch {
        relayError(term, pending.request_id, "out of memory reporting panel asset hydration");
        return;
    };
    defer pending.allocator.free(report);
    var parsed = protocol.parseRequest(pending.allocator, pending.request) catch {
        relayError(term, pending.request_id, "panel request became invalid during hydration");
        return;
    };
    defer parsed.deinit();
    const remote = term.remote orelse return;
    const host = currentHydrationWindow(pending.window, pending.pane);
    const relay = Relay{
        .terminal = term,
        .scope = pending.relay_scope orelse return,
        .pane = pending.pane,
        .window = host,
        .session = remote.session,
        .request_id = pending.request_id,
        .deadline_ms = pending.deadline_ms,
    };
    _ = dispatchRelayNow(host, term, pending.request_id, parsed.value, relay, &pending.resolver, report);
}

/// Direct operations share the origin queue but commit their document before
/// local IO completes. A later refresh of the same path wins; unrelated edits
/// and refreshes do not invalidate this operation.
fn laterDirectRefreshExists(completed: *const Hydration, logical: []const u8) bool {
    for (hydrations.items) |pending| {
        if (pending.direct_panel_id != completed.direct_panel_id or pending.id <= completed.id) continue;
        for (pending.assets) |asset| if (std.mem.eql(u8, asset.logical, logical)) return true;
    }
    return false;
}

fn hydrationReports(pending: *Hydration) ![]assets.Report {
    const report = try pending.allocator.alloc(assets.Report, pending.assets.len);
    for (pending.assets, 0..) |*asset, i| report[i] = .{
        .path = asset.logical,
        .ok = asset.state == .success,
        .bytes = asset.bytes,
        .sha256 = if (asset.hash) |*hash| hash else null,
        .@"error" = asset.failure,
    };
    return report;
}

fn unlinkHydration(pending: *Hydration) bool {
    for (hydrations.items, 0..) |candidate, i| {
        if (candidate != pending) continue;
        _ = hydrations.orderedRemove(i);
        break;
    } else return false;
    if (hydrations.items.len == 0 and hydration_timer != 0) {
        _ = c.g_source_remove(hydration_timer);
        hydration_timer = 0;
    }
    return true;
}

fn cancelHydration(pending: *Hydration) void {
    if (pending.origin.terminal) |terminal| {
        for (pending.assets) |asset| if (asset.state == .reading and asset.read_token != 0)
            terminal.cancelRemoteFileRead(asset.read_token);
    }
    if (!unlinkHydration(pending)) return;
    const scope = pending.relay_scope;
    pending.deinit();
    if (scope) |relay_scope| {
        startNextQueuedPanelOperation(relay_scope);
        releaseRelayScopeIfIdle(relay_scope);
    }
}

fn hydrationTick(_: ?*anyopaque) callconv(.c) c.gboolean {
    const now = @import("../util/clock.zig").nowMs();
    var i: usize = 0;
    while (i < hydrations.items.len) {
        const pending = hydrations.items[i];
        const terminal_live = pending.origin.alive.load(.acquire) and pending.origin.terminal != null;
        const work_live = terminal_live and (pending.direct_panel_id != 0 or
            (pending.origin.terminal.?.remote != null and pending.origin.terminal.?.remote.?.canSend()));
        if (!work_live) {
            cancelHydration(pending);
            continue;
        }
        if (now >= pending.deadline_ms) {
            for (pending.assets) |*asset| {
                if (asset.state == .reading and asset.read_token != 0)
                    pending.origin.terminal.?.cancelRemoteFileRead(asset.read_token);
                if (!isTerminalAssetState(asset.state))
                    failHydrationAsset(asset, "panel asset hydration deadline exceeded");
            }
            maybeCompleteHydration(pending);
            if (i < hydrations.items.len and hydrations.items[i] == pending) i += 1;
            continue;
        }
        i += 1;
    }
    pumpHydrations();
    if (hydrations.items.len == 0) {
        hydration_timer = 0;
        return 0;
    }
    return 1;
}

/// A document/patch failure answers with doc.Diag's own message,
/// VERBATIM: it names the offending component id, and the assistant
/// that wrote the document needs that text to fix it. The error name
/// is only the fallback for a failure that set no diagnostic.
fn diagErr(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    diag: *const Doc.Diag,
    err: anyerror,
) !void {
    const msg = diag.msg();
    if (msg.len > 0) return protocol.writeErr(out, allocator, msg);
    var buf: [64]u8 = undefined;
    const fallback = std.fmt.bufPrint(&buf, "panel rejected: {s}", .{@errorName(err)}) catch "panel rejected";
    return protocol.writeErr(out, allocator, fallback);
}

/// Give up on a half-built panel: free the entry and the view it
/// carries (nothing else can be holding either yet) and fail with
/// `msg` in the diagnostic.
fn abortNew(
    entry: *Entry,
    diag: *Doc.Diag,
    err: ShowError,
    msg: []const u8,
) ShowError {
    const view = entry.view;
    entry.destroy();
    view.deinit();
    diag.set("{s}", .{msg});
    return err;
}

fn panelOpenSession(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    req: protocol.Request,
    relay: ?Relay,
) !DispatchOutcome {
    const source = relay orelse {
        try protocol.writeErr(out, allocator, "panel-open-session is relay-only and cannot use a direct GUI socket");
        return .complete;
    };
    const target_session = req.mux_session orelse {
        try protocol.writeErr(out, allocator, "panel-open-session requires mux_session");
        return .complete;
    };
    const target_origin_id = req.mux_origin_id orelse {
        try protocol.writeErr(out, allocator, "panel-open-session requires mux_origin_id");
        return .complete;
    };
    const request_token = req.request_token orelse {
        try protocol.writeErr(out, allocator, "panel-open-session requires request_token");
        return .complete;
    };
    if (!panelrpc.validRequestToken(request_token)) {
        try protocol.writeErrCode(out, allocator, "invalid_request_token", "panel-open-session request_token is invalid");
        return .complete;
    }

    if (findOpenSessionToken(source.scope, request_token)) |existing| {
        if (!std.mem.eql(u8, existing.target_session, target_session) or
            !std.mem.eql(u8, &existing.target_origin_id, target_origin_id))
        {
            try protocol.writeErrCode(
                out,
                allocator,
                "request_token_conflict",
                "panel-open-session request_token was already used for a different target",
            );
            return .complete;
        }
        if (existing.reply) |reply| {
            try out.appendSlice(allocator, reply);
            return .complete;
        }
        addOpenSessionWaiter(existing, source) catch {
            try protocol.writeErr(out, allocator, "too many retries are waiting for this panel-open-session request");
            return .complete;
        };
        return .pending;
    }

    const token = createOpenSessionToken(source.scope, request_token, target_session, target_origin_id) catch |err| {
        var buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "panel-open-session could not reserve request_token: {s}", .{@errorName(err)}) catch
            "panel-open-session could not reserve request_token";
        try protocol.writeErr(out, allocator, message);
        return .complete;
    };
    addOpenSessionWaiter(token, source) catch |err| {
        removeOpenSessionToken(source.scope, token);
        var buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "panel-open-session could not reserve reply waiter: {s}", .{@errorName(err)}) catch
            "panel-open-session could not reserve reply waiter";
        try protocol.writeErr(out, allocator, message);
        return .complete;
    };
    startPanelOpenSession(source, token, target_session, target_origin_id) catch |err| {
        var buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "panel-open-session could not start: {s}", .{@errorName(err)}) catch
            "panel-open-session could not start";
        try protocol.writeErr(out, allocator, message);
        token.waiters.clearRetainingCapacity();
        cacheOpenSessionReply(source.scope, token, out.items) catch
            removeOpenSessionToken(source.scope, token);
        return .complete;
    };
    return .pending;
}

fn findOpenSessionToken(scope: *RelayScope, request_token: []const u8) ?*OpenSessionToken {
    for (scope.open_session_tokens.items) |token| {
        if (std.mem.eql(u8, token.token, request_token)) return token;
    }
    return null;
}

fn createOpenSessionToken(
    scope: *RelayScope,
    request_token: []const u8,
    target_session: []const u8,
    target_origin_id: []const u8,
) !*OpenSessionToken {
    const a = std.heap.c_allocator;
    const token = try a.create(OpenSessionToken);
    errdefer a.destroy(token);
    const token_copy = try a.dupe(u8, request_token);
    errdefer a.free(token_copy);
    const session_copy = try a.dupe(u8, target_session);
    errdefer a.free(session_copy);
    token.* = .{
        .allocator = a,
        .token = token_copy,
        .target_session = session_copy,
        .target_origin_id = target_origin_id[0..mux_wire.SESSION_ORIGIN_ID_LEN].*,
    };
    try scope.open_session_tokens.append(a, token);
    return token;
}

fn addOpenSessionWaiter(token: *OpenSessionToken, relay: Relay) !void {
    if (token.waiters.items.len >= MAX_OPEN_SESSION_WAITERS) return error.TooManyWaiters;
    const remote = relay.terminal.remote orelse return error.Disconnected;
    try token.waiters.append(token.allocator, .{
        .drain = relay.terminal.drain,
        .generation = remote.panel_generation,
        .request_id = relay.request_id,
    });
}

fn removeOpenSessionToken(scope: *RelayScope, token: *OpenSessionToken) void {
    for (scope.open_session_tokens.items, 0..) |candidate, i| {
        if (candidate != token) continue;
        _ = scope.open_session_tokens.orderedRemove(i);
        token.deinit();
        return;
    }
}

fn cacheOpenSessionReply(scope: *RelayScope, token: *OpenSessionToken, reply: []const u8) !void {
    token.reply = try token.allocator.dupe(u8, reply);
    token.completed_serial = scope.next_open_completion;
    scope.next_open_completion +%= 1;
    if (scope.next_open_completion == 0) scope.next_open_completion = 1;
    pruneOpenSessionReplies(scope);
}

fn pruneOpenSessionReplies(scope: *RelayScope) void {
    while (true) {
        var completed: usize = 0;
        var oldest: ?*OpenSessionToken = null;
        for (scope.open_session_tokens.items) |token| {
            if (token.reply == null) continue;
            completed += 1;
            if (oldest == null or token.completed_serial < oldest.?.completed_serial) oldest = token;
        }
        if (completed <= MAX_OPEN_SESSION_COMPLETED) return;
        removeOpenSessionToken(scope, oldest.?);
    }
}

fn openSessionWaiterTerminal(scope: *RelayScope, waiter: OpenSessionWaiter) ?*Terminal {
    if (!waiter.drain.alive.load(.acquire)) return null;
    const terminal = waiter.drain.terminal orelse return null;
    const remote = terminal.remote orelse return null;
    if (!remote.canSend() or remote.panel_generation != waiter.generation) return null;
    const scope_ctx = terminal.panel_scope_ctx orelse return null;
    if (@as(*RelayScope, @ptrCast(@alignCast(scope_ctx))) != scope) return null;
    return terminal;
}

fn completeOpenSessionToken(scope: *RelayScope, token: *OpenSessionToken, reply: []const u8) void {
    cacheOpenSessionReply(scope, token, reply) catch {
        for (token.waiters.items) |waiter| if (openSessionWaiterTerminal(scope, waiter)) |terminal| {
            relayError(terminal, waiter.request_id, "panel-open-session could not cache its completed reply");
        };
        removeOpenSessionToken(scope, token);
        return;
    };
    for (token.waiters.items) |waiter| if (openSessionWaiterTerminal(scope, waiter)) |terminal| {
        terminal.replyPanelRequest(waiter.request_id, token.reply.?);
    };
    token.waiters.clearRetainingCapacity();
}

fn startPanelOpenSession(
    relay: Relay,
    token: *OpenSessionToken,
    target_session: []const u8,
    target_origin_id: []const u8,
) !void {
    if (@import("../util/clock.zig").nowMs() >= relay.deadline_ms) return error.Timeout;
    if (panel_open_session_jobs.items.len >= MAX_PENDING_PANEL_OPERATIONS) return error.Busy;
    var origin_pending: usize = 0;
    for (panel_open_session_jobs.items) |job| if (job.scope == relay.scope) {
        origin_pending += 1;
    };
    if (origin_pending >= MAX_PENDING_PER_ORIGIN) return error.Busy;
    if (target_session.len < 1 or target_session.len > mux_wire.MAX_SESSION_NAME)
        return error.InvalidSession;
    if (!mux_wire.validSessionOriginId(target_origin_id)) return error.InvalidOriginId;

    const remote = relay.terminal.remote orelse return error.Disconnected;
    if (!remote.canSend()) return error.Disconnected;
    const a = std.heap.c_allocator;
    const socket: ?[]u8 = if (remote.conn.transport == .local)
        try remote.conn.localDaemonOrigin(a)
    else
        null;
    errdefer if (socket) |value| a.free(value);
    const host: ?[]u8 = if (remote.host) |value| try a.dupe(u8, value) else null;
    errdefer if (host) |value| a.free(value);
    if (socket == null and host == null) return error.MissingSourceTransport;
    const port_range: []u8 = if (remote.port_range.len > 0)
        try a.dupe(u8, remote.port_range)
    else
        &.{};
    errdefer if (port_range.len > 0) a.free(port_range);
    const session_copy = try a.dupe(u8, target_session);
    errdefer a.free(session_copy);
    const job = try a.create(PanelOpenSessionJob);
    errdefer a.destroy(job);
    job.* = .{
        .allocator = a,
        .window = relay.window,
        .pane = relay.pane,
        .scope = relay.scope,
        .token = token,
        .origin = relay.terminal.drain,
        .generation = remote.panel_generation,
        .deadline_ms = relay.deadline_ms,
        .target_session = session_copy,
        .target_origin_id = target_origin_id[0..mux_wire.SESSION_ORIGIN_ID_LEN].*,
        .socket = socket,
        .host = host,
        .port_range = port_range,
    };
    try panel_open_session_jobs.append(a, job);
    errdefer _ = panel_open_session_jobs.pop();
    const thread = try std.Thread.spawn(.{}, panelOpenSessionThreadMain, .{job});
    thread.detach();
}

fn removePanelOpenSessionJob(job: *PanelOpenSessionJob) void {
    for (panel_open_session_jobs.items, 0..) |candidate, i| {
        if (candidate != job) continue;
        _ = panel_open_session_jobs.orderedRemove(i);
        return;
    }
}

fn panelOpenSessionThreadMain(job: *PanelOpenSessionJob) void {
    panelOpenSessionConnect(job) catch |err| {
        if (job.failure_len == 0) job.setFailure(@errorName(err));
    };
    _ = c.g_idle_add(@ptrCast(&panelOpenSessionDone), @ptrCast(job));
}

fn panelOpenSessionConnect(job: *PanelOpenSessionJob) !void {
    if (job.canceled.load(.acquire)) return error.Canceled;
    var conn = if (job.socket) |socket|
        try mux_client.Conn.connectProbed(job.allocator, socket)
    else
        try mux_client.Conn.connectRemote(
            job.allocator,
            job.host orelse return error.MissingSourceTransport,
            if (job.port_range.len > 0) job.port_range else null,
        );
    errdefer conn.deinit();
    const cancel_fd = c.fcntl(conn.fd, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
    if (cancel_fd < 0) return error.CancelFdFailed;
    job.cancel_fd.store(cancel_fd, .release);
    if (job.canceled.load(.acquire)) return error.Canceled;

    var remain = job.deadline_ms - @import("../util/clock.zig").nowMs();
    if (remain <= 0) return error.Timeout;
    conn.write_timeout_ms = @intCast(@min(remain, std.math.maxInt(c_int)));
    try conn.sendAttach(job.target_session, .{
        .origin_id = &job.target_origin_id,
        .kind = "gui",
        .panel_rpc = conn.panel_rpc,
    });
    remain = job.deadline_ms - @import("../util/clock.zig").nowMs();
    if (remain <= 0) return error.Timeout;
    const attached = conn.recvGuiAttachFor(remain) catch |err| {
        if (err == error.DaemonError and conn.lastErr().len > 0) job.setFailure(conn.lastErr());
        return err;
    };
    if (!attached.identity.valid or
        !std.mem.eql(u8, attached.identity.originId(), &job.target_origin_id))
    {
        attached.snapshot.deinit(job.allocator);
        job.setFailure("target session origin identity changed");
        return error.SessionOriginMismatch;
    }
    conn.setNonBlocking();
    job.snapshot = attached.snapshot.payload;
    job.identity = attached.identity;
    job.conn = conn;
}

fn panelOpenSessionDone(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(PanelOpenSessionJob, user);
    removePanelOpenSessionJob(job);
    const scope = job.scope;
    defer {
        job.deinit();
        releaseRelayScopeIfIdle(scope);
    }
    const source = panelOpenSessionCommitSource(job) orelse {
        finishOpenSessionError(job, "panel-open-session source scope is no longer available");
        return 0;
    };
    if (job.conn == null or job.snapshot == null) {
        finishOpenSessionError(job, job.failureMessage());
        return 0;
    }
    if (@import("../util/clock.zig").nowMs() >= job.deadline_ms) {
        finishOpenSessionError(job, "panel-open-session deadline exceeded");
        return 0;
    }

    const host = currentHydrationWindow(job.window, source.pane);
    var conn = job.conn.?;
    conn.write_timeout_ms = 0;
    job.conn = null;
    const target_name = job.identity.name();
    const attached = @import("muxtabs.zig").attachMuxPreparedTab(
        host,
        conn,
        target_name,
        if (job.host) |value| value else null,
        job.snapshot.?,
        job.identity,
        .default,
    ) catch |err| {
        var buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "panel-open-session tab commit failed: {s}", .{@errorName(err)}) catch
            "panel-open-session tab commit failed";
        finishOpenSessionError(job, message);
        return 0;
    };
    const target = attached.pane.terminal.remote orelse {
        finishOpenSessionError(job, "panel-open-session target has no mux identity");
        return 0;
    };

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(host.allocator);
    protocol.writeOkFlat(&out, host.allocator, .{
        .session = target.session,
        .origin_id = target.origin_id,
        .tab = remotectl.tabPageId(attached.page),
        .pane = attached.pane.id,
    }) catch {
        // The token must always resolve; a stuck-pending token would make
        // every retry of this idempotent request permanently unanswerable.
        finishOpenSessionError(job, "panel-open-session reply could not be rendered");
        return 0;
    };
    completeOpenSessionToken(job.scope, job.token, out.items);
    return 0;
}

fn finishOpenSessionError(job: *PanelOpenSessionJob, message: []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(job.allocator);
    protocol.writeErr(&out, job.allocator, message) catch return;
    completeOpenSessionToken(job.scope, job.token, out.items);
}

const PanelOpenSessionSource = struct {
    terminal: *Terminal,
    pane: ?*Pane,
};

fn panelOpenSessionCommitSource(job: *const PanelOpenSessionJob) ?PanelOpenSessionSource {
    if (job.canceled.load(.acquire)) return null;
    for (job.scope.viewers.items) |viewer| {
        if (!viewer.drain.alive.load(.acquire)) continue;
        const terminal = viewer.drain.terminal orelse continue;
        const remote = terminal.remote orelse continue;
        if (!remote.canSend()) continue;
        const scope_ctx = terminal.panel_scope_ctx orelse continue;
        const scope: *RelayScope = @ptrCast(@alignCast(scope_ctx));
        if (scope == job.scope and std.mem.eql(u8, remote.origin_id, &scope.origin_id)) return .{
            .terminal = terminal,
            .pane = viewer.pane,
        };
    }
    return null;
}

fn cancelPanelOpenSession(job: *PanelOpenSessionJob) void {
    job.canceled.store(true, .release);
    const fd = job.cancel_fd.load(.acquire);
    if (fd >= 0) _ = c.shutdown(fd, c.SHUT_RDWR);
}

fn startPanelTab(
    relay: Relay,
    request_id: u64,
    name: []const u8,
    document: []const u8,
    resolver: ?*assets.Resolver,
    report_assets: bool,
) !void {
    if (@import("../util/clock.zig").nowMs() >= relay.deadline_ms) return error.Timeout;
    const remote = relay.terminal.remote orelse return error.Disconnected;
    for (panel_tab_jobs.items) |existing| {
        if (existing.scope == relay.scope and std.mem.eql(u8, existing.name, name))
            return error.PanelTabSetupPending;
    }

    const a = std.heap.c_allocator;
    const settings = relay.window.config.profileSettings(relay.window.config.default_profile);
    const shell_source: []const u8 = if (settings.shell) |shell|
        shell
    else if (c.getenv("SHELL")) |shell|
        std.mem.span(shell)
    else
        "/bin/bash";
    var spawned_name_buf: [64]u8 = undefined;
    const spawned_name = Window.nextSessionName(&spawned_name_buf);
    const ipc_path = relay.window.ipc_path orelse "";
    const wayland = if (c.getenv("WAYLAND_DISPLAY")) |display| std.mem.span(display) else "";

    var copies_owned = false;
    const name_copy = try a.dupe(u8, name);
    errdefer if (!copies_owned) a.free(name_copy);
    const document_copy = try a.dupe(u8, document);
    errdefer if (!copies_owned) a.free(document_copy);
    const shell_copy = try a.dupe(u8, shell_source);
    errdefer if (!copies_owned) a.free(shell_copy);
    const term_copy = try a.dupe(u8, settings.term_env);
    errdefer if (!copies_owned) a.free(term_copy);
    const color_term_copy = try a.dupe(u8, settings.color_term_env);
    errdefer if (!copies_owned) a.free(color_term_copy);
    const ipc_copy = try a.dupe(u8, ipc_path);
    errdefer if (!copies_owned) a.free(ipc_copy);
    const wayland_copy = try a.dupe(u8, wayland);
    errdefer if (!copies_owned) a.free(wayland_copy);
    const spawned_copy = try a.dupe(u8, spawned_name);
    errdefer if (!copies_owned) a.free(spawned_copy);

    const job = try a.create(PanelTabJob);
    job.* = .{
        .allocator = a,
        .window = relay.window,
        .pane = relay.pane,
        .scope = relay.scope,
        .origin = relay.terminal.drain,
        .generation = remote.panel_generation,
        .request_id = request_id,
        .deadline_ms = relay.deadline_ms,
        .name = name_copy,
        .spawned_session = spawned_copy,
        .document = document_copy,
        .shell = shell_copy,
        .term = term_copy,
        .color_term = color_term_copy,
        .ipc_path = ipc_copy,
        .wayland_display = wayland_copy,
        .pane_id = relay.window.allocPaneId(),
        .login_shell = settings.login_shell,
        .report_assets = report_assets,
        .resolver = assets.Resolver.init(relay.window.allocator, null),
    };
    copies_owned = true;
    if (resolver) |prepared| job.resolver.replaceFrom(prepared);
    panel_tab_jobs.append(a, job) catch |err| {
        if (resolver) |prepared| prepared.replaceFrom(&job.resolver);
        job.deinit();
        return err;
    };
    const thread = std.Thread.spawn(.{}, panelTabThreadMain, .{job}) catch |err| {
        removePanelTabJob(job);
        if (resolver) |prepared| prepared.replaceFrom(&job.resolver);
        job.deinit();
        return err;
    };
    thread.detach();
}

fn removePanelTabJob(job: *PanelTabJob) void {
    for (panel_tab_jobs.items, 0..) |candidate, i| {
        if (candidate != job) continue;
        _ = panel_tab_jobs.orderedRemove(i);
        return;
    }
}

fn panelTabThreadMain(job: *PanelTabJob) void {
    panelTabConnect(job) catch |err| {
        job.failure = @errorName(err);
    };
    _ = c.g_idle_add(@ptrCast(&panelTabDone), @ptrCast(job));
}

fn panelTabConnect(job: *PanelTabJob) !void {
    if (job.canceled.load(.acquire)) return error.Canceled;
    var conn = try mux_client.Conn.connectLocalAutostart(job.allocator);
    var spawned = false;
    errdefer {
        if (spawned) conn.sendKill(.{
            .name = job.spawned_session,
            .origin_id = if (job.spawned_origin_id_valid) &job.spawned_origin_id else "",
        }) catch {};
        conn.deinit();
    }
    const cancel_fd = c.fcntl(conn.fd, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
    if (cancel_fd < 0) return error.CancelFdFailed;
    job.cancel_fd.store(cancel_fd, .release);
    if (job.canceled.load(.acquire)) return error.Canceled;

    var remain = job.deadline_ms - @import("../util/clock.zig").nowMs();
    if (remain <= 0) return error.Timeout;
    conn.write_timeout_ms = @intCast(@min(remain, std.math.maxInt(c_int)));
    try conn.sendJson(.spawn, .{
        .name = job.spawned_session,
        .argv = @as([]const []const u8, &.{job.shell}),
        .rows = @as(u16, 24),
        .cols = @as(u16, 80),
        .ttl_secs = @as(u32, 60),
        .pane_id = job.pane_id,
        .socket = job.ipc_path,
        .term = job.term,
        .color_term = job.color_term,
        .login_shell = job.login_shell,
        .local = true,
        .host_wayland_display = job.wayland_display,
    });
    remain = job.deadline_ms - @import("../util/clock.zig").nowMs();
    if (remain <= 0) return error.Timeout;
    const ok = try conn.recvExpectFor(&.{.ok}, remain);
    defer ok.deinit(job.allocator);
    const SpawnReply = struct { origin_id: []const u8 = "" };
    var parsed = std.json.parseFromSlice(SpawnReply, job.allocator, ok.payload, .{
        .ignore_unknown_fields = true,
    }) catch return error.MalformedSpawnReply;
    defer parsed.deinit();
    if (!mux_wire.validSessionOriginId(parsed.value.origin_id)) return error.MalformedSpawnReply;
    @memcpy(&job.spawned_origin_id, parsed.value.origin_id);
    job.spawned_origin_id_valid = true;
    spawned = true;
    if (job.canceled.load(.acquire)) return error.Canceled;
    try conn.sendAttach(job.spawned_session, .{
        .origin_id = &job.spawned_origin_id,
        .kind = "gui",
        .panel_rpc = conn.panel_rpc,
    });
    remain = job.deadline_ms - @import("../util/clock.zig").nowMs();
    if (remain <= 0) return error.Timeout;
    const attached = try conn.recvGuiAttachFor(remain);
    conn.setNonBlocking();
    job.snapshot = attached.snapshot.payload;
    job.identity = attached.identity;
    job.conn = conn;
    job.spawned = true;
}

fn panelTabDone(user: ?*anyopaque) callconv(.c) c.gboolean {
    const job = cast.userData(PanelTabJob, user);
    removePanelTabJob(job);
    const scope = job.scope;
    defer {
        job.deinit();
        startNextQueuedPanelOperation(scope);
        releaseRelayScopeIfIdle(scope);
    }
    const terminal = panelTabCommitTerminal(job) orelse return 0;
    const remote = terminal.remote.?;
    if (job.conn == null or job.snapshot == null) {
        relayError(terminal, job.request_id, job.failure);
        return 0;
    }
    if (@import("../util/clock.zig").nowMs() >= job.deadline_ms) {
        relayError(terminal, job.request_id, "panel tab setup deadline exceeded");
        return 0;
    }

    const host = currentHydrationWindow(job.window, job.pane);
    var conn = job.conn.?;
    // Pane construction is main-thread-only. Keep its failure cleanup
    // nonblocking even if this newly attached daemon stops draining now.
    conn.write_timeout_ms = 0;
    job.conn = null;
    job.spawned = false;
    const pane = @import("muxtabs.zig").makeRemotePaneFromSnap(
        host,
        conn,
        job.spawned_session,
        null,
        job.snapshot.?,
        job.identity,
        job.pane_id,
        false,
        false,
        true,
    ) catch |err| {
        var msg_buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&msg_buf, "panel tab pane setup failed: {s}", .{@errorName(err)}) catch
            "panel tab pane setup failed";
        relayError(terminal, job.request_id, message);
        return 0;
    };
    if (pane.terminal.remote) |pane_remote| {
        pane_remote.predictor.force = .never;
    }

    const reports = if (job.report_assets)
        job.resolver.reports(host.allocator) catch {
            host.unlistPane(pane);
            relayError(terminal, job.request_id, "out of memory reporting panel asset hydration");
            return 0;
        }
    else
        null;
    defer if (reports) |items| host.allocator.free(items);

    var diag = Doc.Diag{};
    const entry = showDocumentOrigin(
        host,
        job.pane,
        remote.session,
        job.name,
        job.document,
        .tab,
        .{ .relay = job.scope },
        if (job.report_assets) &job.resolver else null,
        pane,
        &diag,
    ) catch |err| {
        host.unlistPane(pane);
        const message = if (diag.len > 0) diag.msg() else @errorName(err);
        relayError(terminal, job.request_id, message);
        return 0;
    };

    if (entry.pane == pane) {
        const wrapper = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
        c.gtk_widget_set_hexpand(wrapper, 1);
        c.gtk_widget_set_vexpand(wrapper, 1);
        c.gtk_box_append(@ptrCast(wrapper), pane.widget());
        const page = host.appendOrInsertTab(wrapper, .{ .leaf = pane }, false);
        c.adw_tab_page_set_title(page, "Panel");
        c.adw_tab_page_set_tooltip(page, "Panel");
        if (pane.terminal.remote) |pane_remote|
            pane_remote.conn.write_timeout_ms = @import("../mux/client.zig").DEFAULT_WRITE_TIMEOUT_MS;
    } else {
        host.unlistPane(pane);
    }
    presentEntry(host, entry);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(host.allocator);
    if (reports) |items| {
        protocol.writeOkFlat(&out, host.allocator, .{
            .panel_id = entry.panel_id,
            .event_epoch = &entry.event_epoch,
            .session = wireSession(entry.session),
            .assets = items,
            .asset_failures = reportFailureCount(items),
        }) catch return 0;
    } else {
        protocol.writeOkFlat(&out, host.allocator, .{
            .panel_id = entry.panel_id,
            .event_epoch = &entry.event_epoch,
            .session = wireSession(entry.session),
        }) catch return 0;
    }
    terminal.replyPanelRequest(job.request_id, out.items);
    return 0;
}

fn panelTabCommitTerminal(job: *const PanelTabJob) ?*Terminal {
    if (job.canceled.load(.acquire) or !job.origin.alive.load(.acquire)) return null;
    const terminal = job.origin.terminal orelse return null;
    const remote = terminal.remote orelse return null;
    if (!remote.canSend() or remote.panel_generation != job.generation) return null;
    return terminal;
}

fn cancelPanelTabs(terminal: *Terminal) void {
    for (panel_tab_jobs.items) |job| {
        if (job.origin != terminal.drain) continue;
        cancelPanelTab(job);
    }
}

fn cancelPanelTab(job: *PanelTabJob) void {
    job.canceled.store(true, .release);
    const fd = job.cancel_fd.load(.acquire);
    if (fd >= 0) _ = c.shutdown(fd, c.SHUT_RDWR);
}

fn panelShow(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    relay: ?Relay,
    resolver: ?*assets.Resolver,
    report: ?[]const assets.Report,
) !DispatchOutcome {
    const name = req.name orelse {
        try protocol.writeErr(out, allocator, "panel-show requires a name");
        return .complete;
    };
    if (name.len == 0 or name.len > 128) {
        try protocol.writeErr(out, allocator, "panel name must be 1..128 bytes");
        return .complete;
    }
    const document = req.document orelse {
        try protocol.writeErr(out, allocator, "panel-show requires a document (JSON string)");
        return .complete;
    };
    const target = Target.fromName(req.target) orelse {
        try protocol.writeErr(out, allocator, "target must be \"pane\", \"tab\" or \"window\"");
        return .complete;
    };

    // The pane the request came FROM: its session scopes the panel, and
    // for target "pane" it is also the pane that wears the face.
    const origin = if (relay) |r| r.pane else remotectl.reqPane(self, req);
    const session = if (relay) |r| @as(?[]const u8, r.session) else scopeOf(req, origin);
    const host = if (relay) |r| r.window else self;
    const scope: Scope = if (relay) |r| .{ .relay = r.scope } else .direct;
    const replacing = byKey(scope, session, name) != null;

    // A relayed tab needs a daemon-backed Pane, but every socket operation in
    // newShellTab is blocking. Validate now, then prepare that transport on a
    // worker; GTK mounting and the correlated reply happen in its handback.
    if (relay != null and target == .tab and byKey(scope, session, name) == null) {
        var validate_diag = Doc.Diag{};
        var validated = Doc.Document.parse(self.allocator, document, &validate_diag) catch |err| {
            try diagErr(out, allocator, &validate_diag, err);
            return .complete;
        };
        validated.deinit();
        startPanelTab(relay.?, relay.?.request_id, name, document, resolver, report != null) catch |err| {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "panel tab setup could not start: {s}", .{@errorName(err)}) catch
                "panel tab setup could not start";
            try protocol.writeErr(out, allocator, msg);
            return .complete;
        };
        return .pending;
    }

    var diag = Doc.Diag{};
    const entry = showDocumentOrigin(host, origin, session, name, document, target, scope, resolver, null, &diag) catch |err| {
        try diagErr(out, allocator, &diag, err);
        return .complete;
    };
    if (!replacing) presentEntry(host, entry);
    if (relay == null and resolver == null) if (origin orelse host.focusedPane()) |pane| {
        entry.asset_origin = pane.terminal.drain;
        prepareDirectLocalImages(host, pane.terminal.drain, entry, document, null) catch {};
    };
    if (report) |asset_report| {
        try protocol.writeOkFlat(out, allocator, .{
            .panel_id = entry.panel_id,
            .event_epoch = &entry.event_epoch,
            .session = wireSession(entry.session),
            .assets = asset_report,
            .asset_failures = reportFailureCount(asset_report),
        });
    } else {
        try protocol.writeOkFlat(out, allocator, .{
            .panel_id = entry.panel_id,
            .event_epoch = &entry.event_epoch,
            .session = wireSession(entry.session),
        });
    }
    return .complete;
}

pub const ShowError = error{
    /// The document was rejected; `diag` carries the parser's message.
    BadDocument,
    OutOfMemory,
    /// `target = .pane` with no pane to wear the face.
    NoPane,
    /// The panel's own tab or window could not be created.
    NoHost,
    /// Reliable event identity cannot safely be minted without entropy.
    RandomFailed,
};

/// Mount `document` as the panel `(session, name)`. THE mounting path:
/// the control socket and the GUI's own palette both go through it, so
/// the keying and the replace-in-place rule cannot diverge between
/// them. Does NOT raise the panel — callers that want it in front call
/// `presentEntry` (panel-patch deliberately does not).
///
/// Every failure sets `diag`, so one message source explains all of
/// them. On failure nothing is registered and nothing is left on screen.
pub fn showDocument(
    self: *Window,
    origin: ?*Pane,
    session: ?[]const u8,
    name: []const u8,
    document: []const u8,
    target: Target,
    diag: *Doc.Diag,
) ShowError!*Entry {
    const entry = try showDocumentOrigin(self, origin, session, name, document, target, .direct, null, null, diag);
    if (origin) |pane| {
        entry.asset_origin = pane.terminal.drain;
        prepareDirectLocalImages(self, pane.terminal.drain, entry, document, null) catch {};
    }
    return entry;
}

fn showDocumentOrigin(
    self: *Window,
    origin: ?*Pane,
    session: ?[]const u8,
    name: []const u8,
    document: []const u8,
    target: Target,
    scope: Scope,
    resolver: ?*assets.Resolver,
    prepared_tab: ?*Pane,
    diag: *Doc.Diag,
) ShowError!*Entry {
    const allocator = self.allocator;

    // Same (session, name) as a live panel: replace its document in
    // place. That is what makes a training loop's repeated "here is
    // epoch N" cheap — and what keeps one assistant to one panel per
    // name.
    if (byKey(scope, session, name)) |existing| {
        if (resolver) |prepared|
            existing.view.setDocumentResolved(document, prepared, diag) catch return ShowError.BadDocument
        else
            existing.view.setDocument(document, diag) catch return ShowError.BadDocument;
        return existing;
    }

    const view = PanelView.create(allocator) catch return oom(diag);
    // Validate BEFORE hosting: a malformed document must not leave a
    // blank tab or window behind.
    if (resolver) |prepared|
        view.setDocumentResolved(document, prepared, diag) catch {
            view.deinit();
            return ShowError.BadDocument;
        }
    else
        view.setDocument(document, diag) catch {
            view.deinit();
            return ShowError.BadDocument;
        };

    const event_epoch = mux_daemon.newSessionOriginId() catch {
        view.deinit();
        diag.set("panel: cryptographic random source unavailable", .{});
        return ShowError.RandomFailed;
    };
    const entry = allocator.create(Entry) catch {
        view.deinit();
        return oom(diag);
    };
    entry.* = .{
        .allocator = allocator,
        .panel_id = next_panel_id,
        .event_epoch = event_epoch,
        .name = allocator.dupe(u8, name) catch {
            allocator.destroy(entry);
            view.deinit();
            return oom(diag);
        },
        .session = if (session) |sess| allocator.dupe(u8, sess) catch {
            allocator.free(entry.name);
            allocator.destroy(entry);
            view.deinit();
            return oom(diag);
        } else null,
        .scope = scope,
        .target = target,
        .view = view,
        .asset_origin = if (origin) |pane| pane.terminal.drain else null,
    };
    // From here on every failure goes through `abortNew`: the entry is
    // not registered yet, so nothing else can be holding either half.
    switch (target) {
        .pane => {
            const pane = origin orelse
                return abortNew(entry, diag, ShowError.NoPane, "no pane to put the panel on");
            entry.pane = pane;
            register(allocator, entry) catch
                return abortNew(entry, diag, ShowError.OutOfMemory, "panel: out of memory");
            if (!pane.attachPanel(view.root_box, @ptrCast(entry), paneFacePrepare, paneFaceDestroy, paneFaceFocus)) {
                unregister(entry);
                return abortNew(entry, diag, ShowError.NoHost, "panel: pane host is no longer available");
            }
        },
        .tab => {
            const host_win = if (relayScope(scope) != null)
                self
            else if (origin) |p|
                remotectl.ownerWindow(self, p)
            else
                remotectl.activeOrSelf(self);
            const pane = prepared_tab orelse blk: {
                const before = host_win.panes.items.len;
                host_win.newShellTab("Panel") catch
                    return abortNew(entry, diag, ShowError.NoHost, "panel: could not open a tab");
                if (host_win.panes.items.len <= before)
                    return abortNew(entry, diag, ShowError.NoHost, "panel: tab spawn produced no pane");
                break :blk host_win.panes.items[host_win.panes.items.len - 1];
            };
            entry.pane = pane;
            register(allocator, entry) catch
                return abortNew(entry, diag, ShowError.OutOfMemory, "panel: out of memory");
            if (!pane.attachPanel(view.root_box, @ptrCast(entry), paneFacePrepare, paneFaceDestroy, paneFaceFocus)) {
                unregister(entry);
                return abortNew(entry, diag, ShowError.NoHost, "panel: tab pane host is no longer available");
            }
        },
        .window => {
            const app = c.gtk_window_get_application(@ptrCast(self.app_window));
            const pw = PanelWindow.open(allocator, app, view) catch
                return abortNew(entry, diag, ShowError.NoHost, "panel: could not open a window");
            entry.win = pw;
            register(allocator, entry) catch {
                // The window owns the view now; closing it frees both
                // halves through the ordinary destroy/finalize path.
                pw.close();
                entry.destroy();
                diag.set("panel: out of memory", .{});
                return ShowError.OutOfMemory;
            };
            pw.on_closed = &onWindowClosed;
            pw.closed_ctx = @ptrCast(entry);
        },
    }

    next_panel_id += 1;
    return entry;
}

fn oom(diag: *Doc.Diag) ShowError {
    diag.set("panel: out of memory", .{});
    return ShowError.OutOfMemory;
}

/// The scope a panel opened from `pane` gets — the identity behind
/// `$SKETERM_SESSION`, or `null` when the pane has none. THE typed
/// answer; `sessionForPane` is its string rendering.
pub fn sessionScopeForPane(pane: ?*Pane) ?[]const u8 {
    return paneSession(pane);
}

/// `sessionScopeForPane` as a plain string, for GUI callers that both
/// display it and hand it to the store (the saved-panel picker). The
/// empty string is the store's sessionless bucket, never a session.
pub fn sessionForPane(pane: ?*Pane) []const u8 {
    return paneSession(pane) orelse NO_SESSION_WIRE;
}

/// Mount worker-loaded saved bytes and bring the panel to the front.
pub fn openSavedDocument(
    self: *Window,
    pane: ?*Pane,
    name: []const u8,
    json: []const u8,
    target: Target,
    diag: *Doc.Diag,
) !*Entry {
    const session = sessionScopeForPane(pane);
    const entry = try showDocument(self, pane, session, name, json, target, diag);
    presentEntry(self, entry);
    return entry;
}

/// Bring a panel to the front: select its tab and raise its window, or
/// present its standalone window. Never steals focus from a panel the
/// caller is only patching (panel-patch does not call this).
fn presentEntry(self: *Window, entry: *Entry) void {
    if (entry.win) |pw| {
        pw.present();
        return;
    }
    const pane = entry.pane orelse return;
    const win = remotectl.ownerWindow(self, pane);
    pane.setPanelVisible(true);
    if (winmod.tabPageForPane(win, pane)) |page| c.adw_tab_view_set_selected_page(win.tab_view, page);
    c.gtk_window_present(@ptrCast(win.app_window));
}

fn composeDirectResolver(
    allocator: std.mem.Allocator,
    view: *const PanelView,
    paths: []const []u8,
    changed_paths: *const assets.Paths,
    origin_live: bool,
) !assets.Resolver {
    var resolver = assets.Resolver.init(allocator, view.assetCache() orelse panel_asset_cache);
    errdefer resolver.deinit();
    for (paths) |path| {
        const reset = assets.containsPath(changed_paths, path);
        if (reset and origin_live) continue;
        const copied = try view.copyAssetResolution(&resolver, path);
        if (reset and !origin_live and !copied) return error.AssetOriginUnavailable;
    }
    return resolver;
}

fn panelPatch(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    scope: Scope,
    resolver: ?*assets.Resolver,
    report: ?[]const assets.Report,
) !void {
    const id = req.panel_id orelse
        return protocol.writeErr(out, allocator, "panel-patch requires panel_id");
    const patch = req.patch orelse
        return protocol.writeErr(out, allocator, "panel-patch requires patch (JSON array of ops)");
    const entry = byRequestId(self, req, id, scope) orelse
        return protocol.writeErr(out, allocator, "no such panel");
    var diag = Doc.Diag{};
    var direct_changed_paths: ?assets.Paths = null;
    var direct_resolver: ?assets.Resolver = null;
    var direct_origin: ?*DrainHandle = null;
    var direct_origin_live = false;
    defer if (direct_changed_paths) |*paths| paths.deinit();
    defer if (direct_resolver) |*prepared| prepared.deinit();
    if (resolver == null and switch (scope) {
        .direct => true,
        .relay => false,
    }) {
        const current = (entry.view.documentJson(allocator) catch null) orelse
            return protocol.writeErr(out, allocator, "panel has no document");
        defer allocator.free(current);
        var candidate = Doc.Document.parse(allocator, current, &diag) catch |err|
            return diagErr(out, allocator, &diag, err);
        defer candidate.deinit();
        var planned = candidate.applyPatch(patch, &diag) catch |err|
            return diagErr(out, allocator, &diag, err);
        defer planned.deinit();
        direct_changed_paths = assets.collectComponentPaths(allocator, &candidate, planned.set) catch |err| {
            return diagErr(out, allocator, &diag, err);
        };
        var candidate_paths = assets.collectPaths(allocator, &candidate) catch |err|
            return diagErr(out, allocator, &diag, err);
        defer candidate_paths.deinit();

        direct_origin = entry.asset_origin;
        if (direct_origin == null) if (self.focusedPane()) |pane| {
            if (assetOriginUsable(pane.terminal.drain)) {
                direct_origin = pane.terminal.drain;
                entry.asset_origin = direct_origin;
            }
        };
        direct_origin_live = assetOriginUsable(direct_origin);
        direct_resolver = composeDirectResolver(
            allocator,
            entry.view,
            candidate_paths.items,
            &direct_changed_paths.?,
            direct_origin_live,
        ) catch |err| switch (err) {
            error.AssetOriginUnavailable => return protocol.writeErr(
                out,
                allocator,
                "panel asset origin is no longer available; new image sources cannot be hydrated and the patch was not committed",
            ),
            else => return protocol.writeErr(out, allocator, "out of memory composing the direct panel asset transaction"),
        };
    }
    if (resolver) |prepared|
        entry.view.applyPatchResolved(patch, prepared, &diag) catch |err|
            return diagErr(out, allocator, &diag, err)
    else if (direct_resolver) |*prepared|
        entry.view.applyPatchResolved(patch, prepared, &diag) catch |err|
            return diagErr(out, allocator, &diag, err)
    else
        entry.view.applyPatch(patch, &diag) catch |err|
            return diagErr(out, allocator, &diag, err);
    if (direct_changed_paths) |*changed| {
        if (direct_origin_live and changed.items.len > 0) if (direct_origin) |origin| {
            if (entry.view.documentJson(allocator) catch null) |json| {
                defer allocator.free(json);
                prepareDirectLocalImages(self, origin, entry, json, changed) catch {};
            }
        };
    }
    if (report) |asset_report|
        try protocol.writeOkFlat(out, allocator, .{
            .assets = asset_report,
            .asset_failures = reportFailureCount(asset_report),
        })
    else
        try protocol.writeOkFlat(out, allocator, .{});
}

/// Read a live panel's document back, canonically serialized. The
/// registry entry is the only copy that matters, so a panel is
/// readable by any client regardless of which process showed it —
/// which is what lets `ui_save` persist what is on screen without any
/// process keeping a mirror of its own.
fn panelGet(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    scope: Scope,
) !void {
    const id = req.panel_id orelse
        return protocol.writeErr(out, allocator, "panel-get requires panel_id");
    const entry = byRequestId(self, req, id, scope) orelse
        return protocol.writeErr(out, allocator, "no such panel");
    const json = (entry.view.documentJson(allocator) catch null) orelse
        return protocol.writeErr(out, allocator, "panel has no document");
    defer allocator.free(json);
    try protocol.writeOkFlat(out, allocator, .{
        .document = json,
        .event_epoch = &entry.event_epoch,
        .name = entry.name,
        .session = wireSession(entry.session),
        .title = entry.view.title(),
    });
}

/// Drain and answer IMMEDIATELY — this runs on the GLib main loop and
/// must never block (see the module docs).
fn panelEvents(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    scope: Scope,
    reliable: bool,
) !void {
    const id = req.panel_id orelse
        return protocol.writeErr(out, allocator, if (reliable)
            "panel-events-reliable requires panel_id"
        else
            "panel-events requires panel_id");
    const entry = byRequestId(self, req, id, scope) orelse
        return protocol.writeErr(out, allocator, "no such panel");
    if (reliable) panelrpc.validateReliableEventsRequest(
        req.ack,
        req.event_epoch,
        &entry.event_epoch,
    ) catch |err| return protocol.writeErrCode(
        out,
        allocator,
        switch (err) {
            error.MissingEventEpoch => "event_epoch_required",
            error.InvalidEventEpoch => "invalid_event_epoch",
            error.EventEpochMismatch => "event_epoch_mismatch",
        },
        switch (err) {
            error.MissingEventEpoch => "panel-events-reliable requires event_epoch when ack is nonzero",
            error.InvalidEventEpoch => "panel-events-reliable event_epoch is invalid",
            error.EventEpochMismatch => "panel event epoch changed; acknowledgement was not applied",
        },
    );
    try writePanelEvents(&entry.view.queue, entry.event_epoch, req.ack, reliable, out, allocator);
}

/// Serialize either the legacy destructive drain or the v2 acknowledged peek.
/// The 256+ KiB Event scratch lives on the heap, never the GTK main stack.
fn writePanelEvents(
    queue: *events.Queue,
    event_epoch: panelrpc.EventEpoch,
    ack: u64,
    reliable: bool,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
) !void {
    const buf = try allocator.alloc(events.Event, events.CAP);
    defer allocator.free(buf);
    const snapshot = if (reliable) queue.reliableInto(ack, buf) else null;
    const n = if (snapshot) |state| state.count else queue.drainInto(buf);
    const dropped = if (reliable) @as(u64, 0) else queue.takeDropped();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list: std.ArrayList(protocol.PanelEvent) = .empty;
    try list.ensureTotalCapacity(arena, n);
    for (buf[0..n]) |ev| {
        list.appendAssumeCapacity(.{
            .seq = ev.seq,
            .component = try arena.dupe(u8, ev.id()),
            .kind = @tagName(ev.kind),
            .value = switch (ev.value) {
                .none => .null,
                .number => |num| .{ .float = num },
                .boolean => |b| .{ .bool = b },
                .text => |txt| .{ .string = try arena.dupe(u8, txt.slice()) },
            },
            .ts = ev.ts_ms,
        });
    }
    if (snapshot) |state| {
        try protocol.writeOkFlat(out, allocator, .{
            .event_epoch = &event_epoch,
            .events = list.items,
            .cursor = state.cursor,
            .dropped_total = state.dropped_total,
        });
    } else {
        try protocol.writeOkFlat(out, allocator, .{
            .events = list.items,
            .dropped = @as(u32, @intCast(@min(dropped, std.math.maxInt(u32)))),
        });
    }
}

/// Which live panels a `panel-list` is asking for. `none` and a named
/// session are DIFFERENT scopes — a sessionless caller sees sessionless
/// panels, not everyone's.
const Filter = union(enum) {
    /// No session identity anywhere in the request: show everything.
    all,
    /// Explicitly sessionless (`"session":""`).
    none,
    session: []const u8,
};

fn panelList(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    relay: ?Relay,
) !void {
    // Scoping is the point: an assistant lists ITS panels. An explicit
    // session filters to that session and an explicitly EMPTY one to
    // the sessionless panels; otherwise the requesting pane's session
    // filters, and only a caller with no session identity at all — no
    // field, no pane — sees everything.
    const request_origin = if (relay) |r| r.pane else remotectl.reqPane(self, req);
    const filter: Filter = if (relay) |r|
        .{ .session = r.session }
    else if (req.session) |s|
        (if (s.len == 0) .none else .{ .session = s })
    else if (paneSession(request_origin)) |s|
        .{ .session = s }
    else
        .all;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var list: std.ArrayList(protocol.PanelInfo) = .empty;
    const request_scope: Scope = if (relay) |r| .{ .relay = r.scope } else .direct;
    for (panels.items) |e| {
        if (!sameScope(e.scope, request_scope)) continue;
        switch (filter) {
            .all => {},
            .none => if (e.session != null) continue,
            .session => |want| if (!sameSession(e.session, want)) continue,
        }
        try list.append(arena, .{
            .panel_id = e.panel_id,
            .event_epoch = &e.event_epoch,
            .name = e.name,
            .session = wireSession(e.session),
            .title = e.view.title(),
            .target = e.target.name(),
        });
    }
    try protocol.writeOkFlat(out, allocator, .{ .panels = list.items });
}

fn panelClose(
    self: *Window,
    req: protocol.Request,
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    scope: Scope,
) !void {
    const id = req.panel_id orelse
        return protocol.writeErr(out, allocator, "panel-close requires panel_id");
    const entry = byRequestId(self, req, id, scope) orelse
        return protocol.writeErr(out, allocator, "no such panel");
    closeEntry(self, entry);
    try protocol.writeOkFlat(out, allocator, .{});
}

/// Take a panel off the screen. Every branch reaches an unregister +
/// free of `entry` (through the face/window teardown trampolines), so
/// nothing may touch it afterwards.
fn closeEntry(self: *Window, entry: *Entry) void {
    _ = self;
    entry.closing = true;
    cancelEntryWork(entry);
    const target = entry.target;
    const pane = entry.pane;
    if (entry.win) |pw| {
        pw.close();
    } else if (pane) |p| switch (target) {
        // The panel was put ON an existing pane: give the pane back to
        // its shell rather than closing the user's terminal.
        .pane => p.detachPanel(),
        // Relinquish addressability and restore the shell before replying;
        // the tab close may be confirmed or canceled on a later main-loop turn.
        .tab => detachPanelAndScheduleTabClose(p),
        // Every .window entry sets `win` at registration, so the branch
        // above already handled it; not `unreachable` because ReleaseFast
        // would make a future regression UB instead of a no-op.
        .window => return,
    };
}

fn cancelEntryWork(entry: *Entry) void {
    switch (entry.scope) {
        .relay => return,
        .direct => {},
    }
    while (true) {
        var found: ?*Hydration = null;
        for (hydrations.items) |pending| {
            if (pending.direct_panel_id != entry.panel_id) continue;
            found = pending;
            break;
        }
        cancelHydration(found orelse return);
    }
}

const DeferredPanelTabClose = struct {
    drain: *DrainHandle,
    pane: *Pane,
};

fn detachPanelAndScheduleTabClose(pane: *Pane) void {
    const drain = pane.terminal.drain;
    pane.detachPanel();
    const pending = std.heap.c_allocator.create(DeferredPanelTabClose) catch return;
    pending.* = .{ .drain = drain, .pane = pane };
    _ = c.g_idle_add(@ptrCast(&closeDetachedPanelTab), @ptrCast(pending));
}

fn closeDetachedPanelTab(user: ?*anyopaque) callconv(.c) c.gboolean {
    const pending = cast.userData(DeferredPanelTabClose, user);
    defer std.heap.c_allocator.destroy(pending);
    if (!pending.drain.alive.load(.acquire)) return 0;
    const terminal = pending.drain.terminal orelse return 0;
    const pane = pending.pane;
    if (pane.terminal != terminal) return 0;
    const owner_ctx = pane.win_clip_ctx orelse return 0;
    const owner: *Window = @ptrCast(@alignCast(owner_ctx));
    if (!owner.destroying) owner.closePane(pane);
    return 0;
}

/// Drop every uncommitted panel operation for a transport that vanished.
/// Existing panels and committed direct local-file hydrations survive reconnect.
pub fn cancelPanelWork(terminal: *Terminal) void {
    cancelTerminalPanelWork(terminal, false);
}

fn cancelTerminalPanelWork(terminal: *Terminal, permanent: bool) void {
    cancelPanelTabs(terminal);
    const scope: ?*RelayScope = if (terminal.panel_scope_ctx) |ctx| @ptrCast(@alignCast(ctx)) else null;
    var i: usize = 0;
    while (i < queued_panel_operations.items.len) {
        const queued = queued_panel_operations.items[i];
        if (queued.origin != terminal.drain) {
            i += 1;
            continue;
        }
        _ = queued_panel_operations.orderedRemove(i);
        queued.deinit();
    }
    while (true) {
        var pending_match: ?*Hydration = null;
        for (hydrations.items) |pending| if (pending.origin == terminal.drain) {
            if (!permanent and pending.direct_panel_id != 0) continue;
            pending_match = pending;
            break;
        };
        const pending = pending_match orelse break;
        cancelHydration(pending);
    }
    if (scope) |relay_scope| if (!hasActivePanelWork(relay_scope))
        startNextQueuedPanelOperation(relay_scope);
}

fn cancelScopePanelWork(scope: *RelayScope) void {
    for (panel_tab_jobs.items) |job| if (job.scope == scope) cancelPanelTab(job);
    for (panel_open_session_jobs.items) |job| if (job.scope == scope) cancelPanelOpenSession(job);
    var i: usize = 0;
    while (i < queued_panel_operations.items.len) {
        const queued = queued_panel_operations.items[i];
        if (queued.scope != scope) {
            i += 1;
            continue;
        }
        _ = queued_panel_operations.orderedRemove(i);
        queued.deinit();
    }
    while (true) {
        var found: ?*Hydration = null;
        for (hydrations.items) |pending| if (pending.relay_scope == scope) {
            found = pending;
            break;
        };
        cancelHydration(found orelse break);
    }
}

/// Release one attachment; only permanent last-viewer teardown closes panels.
pub fn closeOrigin(terminal: *Terminal) void {
    cancelTerminalPanelWork(terminal, true);
    const scope = detachOriginScope(terminal) orelse return;
    cancelScopePanelWork(scope);
    while (true) {
        // Adw tab closure completes through a later main-loop turn. Remove
        // addressability first so this loop cannot rediscover the same entry;
        // its face/window destroy trampoline still owns the exactly-once free.
        const entry = takeOriginEntry(scope) orelse break;
        entry.closing = true;
        if (entry.win) |pw| {
            pw.close();
        } else if (entry.pane) |pane| {
            const target = entry.target;
            if (target == .tab)
                detachPanelAndScheduleTabClose(pane)
            else
                pane.detachPanel();
        } else {
            entry.view.deinit();
            entry.destroy();
        }
    }
    releaseRelayScopeIfIdle(scope);
}

fn takeOriginEntry(scope: *RelayScope) ?*Entry {
    for (panels.items, 0..) |entry, i| {
        if (relayScope(entry.scope) == scope) return panels.orderedRemove(i);
    }
    return null;
}

/// Update mutable panel metadata after a daemon rename without changing the
/// exact relay namespace used for confinement and replacement.
pub fn renameOrigin(terminal: *Terminal, name: []const u8) void {
    const scope = relayScopeForTerminal(terminal) orelse return;
    for (panels.items) |entry| {
        if (relayScope(entry.scope) != scope) continue;
        const fresh = entry.allocator.dupe(u8, name) catch continue;
        if (entry.session) |old| entry.allocator.free(old);
        entry.session = fresh;
    }
}

/// Close the panel the user means — the GUI's own close path (the
/// palette's "Close Panel"), with the same teardown as `panel-close`.
/// @return whether one was closed.
///
/// The ladder — the pane itself, then its tab, then the window when it
/// hosts exactly one panel — is not generosity: a panel face has no key
/// controller of its own, so the command palette can only be opened
/// from a pane that is NOT the panel, and "the focused pane's panel"
/// alone would be an action nobody could ever reach. Standalone panel
/// windows are excluded: they have a titlebar close button.
pub fn closeNearest(self: *Window, pane: ?*Pane) bool {
    if (pane) |p| {
        for (panels.items) |e| {
            if (e.pane == p) {
                closeEntry(self, e);
                return true;
            }
        }
        if (winmod.tabPageForPane(self, p)) |page| {
            if (Window.tabTreeOf(page)) |t| {
                for (panels.items) |e| {
                    const ep = e.pane orelse continue;
                    if (t.contains(ep)) {
                        closeEntry(self, e);
                        return true;
                    }
                }
            }
        }
    }
    var only: ?*Entry = null;
    for (panels.items) |e| {
        const ep = e.pane orelse continue;
        if (!ownsPane(self, ep)) continue;
        if (only != null) return false; // ambiguous: say nothing, do nothing
        only = e;
    }
    if (only) |e| {
        closeEntry(self, e);
        return true;
    }
    return false;
}

fn ownsPane(self: *Window, pane: *Pane) bool {
    for (self.panes.items) |p| {
        if (p == pane) return true;
    }
    return false;
}

// ─── face trampolines ───────────────────────────────────────────
//
// The registry entry IS the pane face's context, so teardown from any
// pane path (severFaces, close, tab sweep) drops the panel from the
// registry before the view is freed.

fn paneFacePrepare(ctx: *anyopaque, widgets_dead: bool) void {
    const entry = canary.live(Entry, ctx) orelse return;
    entry.rehost_pane = null;
    if (!widgets_dead and !entry.closing and entry.target == .pane) {
        if (entry.pane) |pane| if (pane.isSeveringFaces()) {
            entry.rehost_pane = survivingScopePane(entry, pane);
            if (entry.rehost_pane != null) return;
        };
    }
    entry.view.prepareDestroy(widgets_dead);
}

fn paneFaceDestroy(ctx: *anyopaque) void {
    const entry = canary.live(Entry, ctx) orelse return;
    if (entry.rehost_pane) |pane| {
        entry.rehost_pane = null;
        entry.pane = pane;
        if (pane.attachPanel(
            entry.view.root_box,
            @ptrCast(entry),
            paneFacePrepare,
            paneFaceDestroy,
            paneFaceFocus,
        )) return;
        entry.pane = null;
        entry.view.prepareDestroy(false);
    }
    cancelEntryWork(entry);
    unregister(entry);
    entry.view.deinit();
    entry.destroy();
}

fn survivingScopePane(entry: *const Entry, closing: *const Pane) ?*Pane {
    const scope = relayScope(entry.scope) orelse return null;
    for (scope.viewers.items) |viewer| {
        const pane = viewer.pane orelse continue;
        if (pane == closing or !pane.canAdoptPanelFace()) continue;
        if (!viewer.drain.alive.load(.acquire) or viewer.drain.terminal == null) continue;
        const scope_ctx = pane.terminal.panel_scope_ctx orelse continue;
        const pane_scope: *RelayScope = @ptrCast(@alignCast(scope_ctx));
        if (pane_scope == scope) return pane;
    }
    return null;
}

fn paneFaceFocus(ctx: *anyopaque) void {
    const entry = canary.live(Entry, ctx) orelse return;
    entry.view.focusFace();
}

/// A panel window's ::destroy. The window still owns (and later frees)
/// the view at its finalize; the entry only stops being addressable.
fn onWindowClosed(ctx: *anyopaque) void {
    const entry = canary.live(Entry, ctx) orelse return;
    cancelEntryWork(entry);
    unregister(entry);
    entry.destroy();
}

// ─── tests ──────────────────────────────────────────────────────

const TEST_EVENT_EPOCH: panelrpc.EventEpoch = "10000000000000000000000000000001".*;

test "every panel-host decl type-checks" {
    // Lazy analysis: a signature error in a trampoline no test calls
    // would otherwise slip through `zig build test`.
    std.testing.refAllDecls(@This());
}

test "target names round-trip, and default to a tab" {
    try std.testing.expectEqual(Target.tab, Target.fromName(null).?);
    try std.testing.expectEqual(Target.tab, Target.fromName("").?);
    try std.testing.expectEqual(Target.pane, Target.fromName("pane").?);
    try std.testing.expectEqual(Target.window, Target.fromName("window").?);
    try std.testing.expectEqual(@as(?Target, null), Target.fromName("popover"));
    try std.testing.expectEqualStrings("window", Target.window.name());
}

test "new panel event epochs have the session-origin shape and do not repeat" {
    const first = try mux_daemon.newSessionOriginId();
    const second = try mux_daemon.newSessionOriginId();
    try std.testing.expect(panelrpc.validEventEpoch(&first));
    try std.testing.expect(panelrpc.validEventEpoch(&second));
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "a sessionless panel-show and a sessionless store operation agree on the key" {
    // `resolveSession` consults the environment, and this test may well
    // be run from inside a sketerm pane.
    _ = c.unsetenv("SKETERM_SESSION");

    // What panel-show scopes to with neither an explicit session nor a
    // pane to inherit one from...
    const scoped = scopeOf(.{ .cmd = "panel-show", .name = "p" }, null);
    try std.testing.expectEqual(@as(?[]const u8, null), scoped);
    // ...is exactly what the store resolves to for the same caller: no
    // session, expressed as an absence on both sides rather than as a
    // name the two halves could spell differently.
    try std.testing.expectEqual(@as(?[]const u8, null), panelstore.resolveSession(.absent));

    // An explicitly empty `session` field says the same thing, and does
    // NOT fall through to a pane's session.
    try std.testing.expectEqual(
        @as(?[]const u8, null),
        scopeOf(.{ .cmd = "panel-show", .name = "p", .session = NO_SESSION_WIRE }, null),
    );
    try std.testing.expectEqualStrings(NO_SESSION_WIRE, wireSession(scoped));

    // And the store files it apart from every session, including one
    // named like the bucket's own directory or like the old sentinel.
    const a = std.testing.allocator;
    const none_dir = try panelstore.sessionDir(a, scoped);
    defer a.free(none_dir);
    try std.testing.expect(std.mem.endsWith(u8, none_dir, panelstore.NO_SESSION_DIR));
    for ([_][]const u8{ "_no-session", panelstore.NO_SESSION_DIR, "default" }) |name| {
        const dir = try panelstore.sessionDir(a, name);
        defer a.free(dir);
        try std.testing.expect(!std.mem.eql(u8, dir, none_dir));
    }
}

test "registry keys by (session, name)" {
    const a = std.testing.allocator;
    panels = .empty;
    defer {
        panels.deinit(a);
        panels = .empty;
    }
    var fake_view: PanelView = undefined;
    var e1 = Entry{
        .allocator = a,
        .panel_id = 1,
        .event_epoch = TEST_EVENT_EPOCH,
        .name = @constCast("train"),
        .session = @constCast("s1"),
        .target = .tab,
        .view = &fake_view,
    };
    var e2 = Entry{
        .allocator = a,
        .panel_id = 2,
        .event_epoch = TEST_EVENT_EPOCH,
        .name = @constCast("train"),
        .session = @constCast("s2"),
        .target = .window,
        .view = &fake_view,
    };
    var e3 = Entry{
        .allocator = a,
        .panel_id = 3,
        .event_epoch = TEST_EVENT_EPOCH,
        .name = @constCast("train"),
        .session = null,
        .target = .tab,
        .view = &fake_view,
    };
    try register(a, &e1);
    try register(a, &e2);
    try register(a, &e3);
    // Same name, different sessions: two distinct panels.
    try std.testing.expectEqual(@as(u32, 1), byKey(.direct, "s1", "train").?.panel_id);
    try std.testing.expectEqual(@as(u32, 2), byKey(.direct, "s2", "train").?.panel_id);
    try std.testing.expectEqual(@as(?*Entry, null), byKey(.direct, "s3", "train"));
    try std.testing.expectEqual(@as(u32, 2), byId(2, .direct).?.panel_id);
    var fake_window: Window = undefined;
    try std.testing.expectEqual(&e1, byRequestId(
        &fake_window,
        .{ .cmd = "panel-get", .panel_id = 1, .session = "s1" },
        1,
        .direct,
    ).?);
    try std.testing.expectEqual(@as(?*Entry, null), byRequestId(
        &fake_window,
        .{ .cmd = "panel-get", .panel_id = 1, .session = "s2" },
        1,
        .direct,
    ));
    // Sessionless is a THIRD key, not a session named anything: no
    // session name reaches it, and it reaches no session's panel.
    try std.testing.expectEqual(@as(u32, 3), byKey(.direct, null, "train").?.panel_id);
    try std.testing.expectEqual(@as(?*Entry, null), byKey(.direct, "_no-session", "train"));
    try std.testing.expectEqual(&e3, byRequestId(
        &fake_window,
        .{ .cmd = "panel-close", .panel_id = 3, .session = NO_SESSION_WIRE },
        3,
        .direct,
    ).?);
    try std.testing.expectEqual(@as(?*Entry, null), byRequestId(
        &fake_window,
        .{ .cmd = "panel-close", .panel_id = 3, .session = "s1" },
        3,
        .direct,
    ));
    unregister(&e3);
    try std.testing.expectEqual(@as(?*Entry, null), byKey(.direct, null, "train"));
    unregister(&e1);
    try std.testing.expectEqual(@as(?*Entry, null), byKey(.direct, "s1", "train"));
    try std.testing.expectEqual(@as(usize, 1), panels.items.len);
    unregister(&e2);
    try std.testing.expectEqual(@as(usize, 0), panels.items.len);
}

test "relay registry qualifies keys by session lifetime origin" {
    const a = std.testing.allocator;
    panels = .empty;
    defer {
        panels.deinit(a);
        panels = .empty;
    }

    var scope_a = RelayScope{
        .origin_id = "11000000000000000000000000000001".*,
    };
    var scope_b = RelayScope{
        .origin_id = "22000000000000000000000000000002".*,
    };
    try std.testing.expect(sameRelayKey(&scope_a, &scope_a.origin_id));
    try std.testing.expect(!sameRelayKey(&scope_a, &scope_b.origin_id));
    try std.testing.expect(!sameRelayKey(&scope_b, &scope_a.origin_id));
    var fake_view: PanelView = undefined;
    const a_session = try a.dupe(u8, "same-session");
    var a_entry = Entry{
        .allocator = a,
        .panel_id = 41,
        .event_epoch = TEST_EVENT_EPOCH,
        .name = @constCast("same-name"),
        .session = a_session,
        .scope = .{ .relay = &scope_a },
        .target = .tab,
        .view = &fake_view,
    };
    defer a.free(a_entry.session.?);
    var b_entry = Entry{
        .allocator = a,
        .panel_id = 42,
        .event_epoch = TEST_EVENT_EPOCH,
        .name = @constCast("same-name"),
        .session = @constCast("same-session"),
        .scope = .{ .relay = &scope_b },
        .target = .window,
        .view = &fake_view,
    };
    try register(a, &a_entry);
    try register(a, &b_entry);

    try std.testing.expectEqual(@as(u32, 41), byKey(.{ .relay = &scope_a }, "same-session", "same-name").?.panel_id);
    try std.testing.expectEqual(@as(u32, 42), byKey(.{ .relay = &scope_b }, "same-session", "same-name").?.panel_id);
    try std.testing.expectEqual(@as(u32, 41), byId(41, .{ .relay = &scope_a }).?.panel_id);
    try std.testing.expectEqual(@as(?*Entry, null), byId(42, .{ .relay = &scope_a }));
    try std.testing.expectEqual(@as(?*Entry, null), byId(41, .{ .relay = &scope_b }));

    // Direct GUI-socket calls never wildcard across relay namespaces.
    try std.testing.expectEqual(@as(?*Entry, null), byId(42, .direct));

    // Rename changes display metadata but the immutable origin still finds and
    // replaces the same panel; an equal display name on another origin stays
    // separate.
    var fake_term: Terminal = undefined;
    fake_term.panel_scope_ctx = @ptrCast(&scope_a);
    renameOrigin(&fake_term, "renamed-session");
    try std.testing.expectEqualStrings("renamed-session", a_entry.session.?);
    try std.testing.expectEqual(@as(u32, 41), byKey(.{ .relay = &scope_a }, "renamed-session", "same-name").?.panel_id);
    try std.testing.expectEqual(@as(u32, 42), byKey(.{ .relay = &scope_b }, "same-session", "same-name").?.panel_id);

    unregister(&a_entry);
    unregister(&b_entry);
}

test "same-process duplicate attachments share panels through reconnect until last teardown" {
    const a = std.testing.allocator;
    panels = .empty;
    relay_scopes = .empty;
    defer {
        panels.deinit(a);
        panels = .empty;
        for (relay_scopes.items) |scope| {
            scope.viewers.deinit(std.heap.c_allocator);
            std.heap.c_allocator.destroy(scope);
        }
        relay_scopes.deinit(std.heap.c_allocator);
        relay_scopes = .empty;
    }

    const origin_id = "33000000000000000000000000000003";
    var remote_a = Terminal.Remote{
        .conn = .{ .allocator = a, .fd = -1, .panel_rpc = mux_wire.PANEL_RPC_VERSION },
        .session = @constCast("shared"),
        .origin_name = @constCast("shared"),
        .origin_id = @constCast(origin_id),
        .predictor = undefined,
    };
    var remote_b = Terminal.Remote{
        .conn = .{ .allocator = a, .fd = -1, .panel_rpc = mux_wire.PANEL_RPC_VERSION },
        .session = @constCast("shared"),
        .origin_name = @constCast("shared"),
        .origin_id = @constCast(origin_id),
        .predictor = undefined,
    };
    var drain_a = DrainHandle{};
    var drain_b = DrainHandle{};
    var term_a: Terminal = undefined;
    term_a.allocator = a;
    term_a.remote = &remote_a;
    term_a.drain = &drain_a;
    term_a.panel_scope_ctx = null;
    var term_b: Terminal = undefined;
    term_b.allocator = a;
    term_b.remote = &remote_b;
    term_b.drain = &drain_b;
    term_b.panel_scope_ctx = null;
    drain_a.terminal = &term_a;
    drain_b.terminal = &term_b;

    var pane_a: Pane = undefined;
    var pane_b: Pane = undefined;
    attachOrigin(&term_a, &pane_a);
    attachOrigin(&term_b, &pane_b);
    const shared: *RelayScope = @ptrCast(@alignCast(term_a.panel_scope_ctx.?));
    try std.testing.expectEqual(term_a.panel_scope_ctx, term_b.panel_scope_ctx);
    try std.testing.expectEqual(@as(usize, 2), shared.viewers.items.len);
    try std.testing.expectEqual(&pane_a, shared.viewers.items[0].pane.?);
    try std.testing.expectEqual(&pane_b, shared.viewers.items[1].pane.?);

    var fake_view: PanelView = undefined;
    var entry = Entry{
        .allocator = a,
        .panel_id = 77,
        .event_epoch = TEST_EVENT_EPOCH,
        .name = @constCast("shared-panel"),
        .session = @constCast("shared"),
        .scope = .{ .relay = shared },
        .target = .window,
        .view = &fake_view,
    };
    try register(a, &entry);

    // Either daemon-selected attachment resolves the same registry even when
    // routing order changes, and a reconnect does not alter that scope.
    try std.testing.expectEqual(&entry, byId(77, .{ .relay = relayScopeForTerminal(&term_b).? }).?);
    try std.testing.expectEqual(&entry, byId(77, .{ .relay = relayScopeForTerminal(&term_a).? }).?);
    remote_a.connected = false;
    cancelPanelWork(&term_a);
    remote_a.connected = true;
    try std.testing.expectEqual(shared, relayScopeForTerminal(&term_a).?);

    remote_a.closed = true;
    closeOrigin(&term_a);
    try std.testing.expectEqual(@as(usize, 1), shared.viewers.items.len);
    try std.testing.expectEqual(&pane_b, shared.viewers.items[0].pane.?);
    try std.testing.expectEqual(&entry, byId(77, .{ .relay = relayScopeForTerminal(&term_b).? }).?);

    // Materializing the exited AppSession wires pane callbacks again. A dead
    // Terminal must not re-attach and keep the live viewer's scope pinned.
    attachOrigin(&term_a, null);
    try std.testing.expect(term_a.panel_scope_ctx == null);
    try std.testing.expectEqual(@as(usize, 1), shared.viewers.items.len);

    const last = detachOriginScope(&term_b).?;
    try std.testing.expectEqual(shared, last);
    try std.testing.expectEqual(&entry, takeOriginEntry(last).?);
    try std.testing.expectEqual(@as(usize, 0), panels.items.len);
}

test "AppSession adoption rebinds hydration queue and panel-tab ownership" {
    const a = std.testing.allocator;
    hydrations = .empty;
    queued_panel_operations = .empty;
    panel_tab_jobs = .empty;
    defer {
        hydrations.deinit(a);
        queued_panel_operations.deinit(a);
        panel_tab_jobs.deinit(a);
        hydrations = .empty;
        queued_panel_operations = .empty;
        panel_tab_jobs = .empty;
    }

    var source: Window = undefined;
    var destination: Window = undefined;
    var pane: Pane = undefined;
    pane.win_clip_ctx = @ptrCast(&destination);
    var drain = DrainHandle{};
    var terminal: Terminal = undefined;
    terminal.drain = &drain;
    drain.terminal = &terminal;

    var hydration: Hydration = undefined;
    hydration.origin = &drain;
    hydration.window = &source;
    hydration.pane = null;
    var scope: RelayScope = undefined;
    var queued: QueuedPanelOperation = undefined;
    queued.origin = &drain;
    queued.scope = &scope;
    queued.window = &source;
    queued.pane = null;
    var tab_job: PanelTabJob = undefined;
    tab_job.origin = &drain;
    tab_job.scope = &scope;
    tab_job.window = &source;
    tab_job.pane = null;
    try hydrations.append(a, &hydration);
    try queued_panel_operations.append(a, &queued);
    try panel_tab_jobs.append(a, &tab_job);

    adoptTerminalOwner(&terminal, &pane, &destination);
    source.destroying = true;
    try std.testing.expectEqual(&destination, hydration.window);
    try std.testing.expectEqual(&pane, hydration.pane.?);
    try std.testing.expectEqual(&destination, queued.window);
    try std.testing.expectEqual(&pane, queued.pane.?);
    try std.testing.expectEqual(&destination, tab_job.window);
    try std.testing.expectEqual(&pane, tab_job.pane.?);
    try std.testing.expectEqual(&destination, currentHydrationWindow(hydration.window, hydration.pane));
}

test "direct non-image composition immediately drops removed and reset leases" {
    const a = std.testing.allocator;
    var cache = try assets.Cache.initAt(a, "/tmp/sketerm-panel-direct-compose");
    defer cache.deinit();
    const removed_hash: [64]u8 = @splat('a');
    const kept_hash: [64]u8 = @splat('b');

    var view: PanelView = undefined;
    view.allocator = a;
    view.asset_resolver = assets.Resolver.init(a, &cache);
    defer view.asset_resolver.deinit();
    try view.asset_resolver.addSuccess("/removed.png", "/cache/removed", removed_hash, 1);
    try view.asset_resolver.addSuccess("/kept.png", "/cache/kept", kept_hash, 1);

    var no_changed_items: [0][]u8 = .{};
    var no_changed = assets.Paths{ .allocator = a, .items = &no_changed_items };
    const non_image_paths = [_][]u8{@constCast("/kept.png")};
    var after_non_image = try composeDirectResolver(a, &view, &non_image_paths, &no_changed, true);
    view.asset_resolver.replaceFrom(&after_non_image);
    try std.testing.expectEqual(@as(usize, 0), cache.refCount(&removed_hash));
    try std.testing.expectEqual(@as(usize, 1), cache.refCount(&kept_hash));

    var changed_items = [_][]u8{@constCast("/kept.png")};
    var changed = assets.Paths{ .allocator = a, .items = &changed_items };
    var after_reset = try composeDirectResolver(a, &view, &non_image_paths, &changed, true);
    view.asset_resolver.replaceFrom(&after_reset);
    try std.testing.expectEqual(@as(usize, 0), cache.refCount(&kept_hash));
    try std.testing.expectEqual(@as(usize, 0), view.asset_resolver.entries.items.len);
}

test "closing a direct panel removes hydration before late worker handback" {
    const a = std.testing.allocator;
    hydrations = .empty;
    defer {
        hydrations.deinit(a);
        hydrations = .empty;
    }
    var drain = DrainHandle{};
    var terminal: Terminal = undefined;
    terminal.drain = &drain;
    terminal.remote = null;
    drain.terminal = &terminal;
    const pending = try a.create(Hydration);
    pending.* = .{
        .allocator = a,
        .id = 0x55aa,
        .origin = &drain,
        .window = undefined,
        .pane = null,
        .request_id = 0,
        .request = try a.alloc(u8, 0),
        .assets = try a.alloc(HydrationAsset, 0),
        .read_source = .local,
        .resolver = assets.Resolver.init(a, null),
        .direct_panel_id = 991,
        .deadline_ms = std.math.maxInt(i64),
    };
    try hydrations.append(a, pending);
    var fake_view: PanelView = undefined;
    var entry = Entry{
        .allocator = a,
        .panel_id = 991,
        .event_epoch = TEST_EVENT_EPOCH,
        .name = @constCast("closing"),
        .session = null,
        .target = .window,
        .view = &fake_view,
    };
    cancelEntryWork(&entry);
    try std.testing.expectEqual(@as(usize, 0), hydrations.items.len);

    const ca = std.heap.c_allocator;
    const late = try ca.create(CacheJob);
    late.* = .{
        .drain = &drain,
        .pending_id = 0x55aa,
        .asset_index = 0,
        .nonce = 1,
        .root = try ca.dupe(u8, "/tmp/sketerm-panel-late-direct"),
        .bytes = try ca.alloc(u8, 0),
        .bytes_allocator = ca,
        .protected = try ca.alloc([64]u8, 0),
        .ready = .init(true),
    };
    active_cache_jobs = 1;
    try std.testing.expectEqual(@as(c.gboolean, 0), cacheJobDone(@ptrCast(late)));
    try std.testing.expectEqual(@as(usize, 0), active_cache_jobs);
    try std.testing.expectEqual(@as(usize, 0), hydrations.items.len);
}

test "scope extraction cannot spin while tab closure is deferred" {
    const a = std.testing.allocator;
    panels = .empty;
    defer {
        panels.deinit(a);
        panels = .empty;
    }
    var drain = DrainHandle{};
    var scope = RelayScope{
        .origin_id = "11000000000000000000000000000001".*,
    };
    var fake_view: PanelView = undefined;
    var first = Entry{
        .allocator = a,
        .panel_id = 1,
        .event_epoch = TEST_EVENT_EPOCH,
        .name = @constCast("first"),
        .session = @constCast("s"),
        .scope = .{ .relay = &scope },
        .target = .tab,
        .view = &fake_view,
    };
    var second = Entry{
        .allocator = a,
        .panel_id = 2,
        .event_epoch = TEST_EVENT_EPOCH,
        .name = @constCast("second"),
        .session = @constCast("s"),
        .scope = .{ .relay = &scope },
        .target = .tab,
        .view = &fake_view,
    };
    try register(a, &first);
    try register(a, &second);
    try std.testing.expectEqual(&first, takeOriginEntry(&scope).?);
    try std.testing.expectEqual(&second, takeOriginEntry(&scope).?);
    try std.testing.expectEqual(@as(?*Entry, null), takeOriginEntry(&scope));
    try std.testing.expectEqual(@as(usize, 0), panels.items.len);

    // A queued tab close whose terminal died before the idle handback must not
    // dereference the stale Pane pointer.
    drain.alive.store(false, .release);
    const pending = try std.heap.c_allocator.create(DeferredPanelTabClose);
    pending.* = .{ .drain = &drain, .pane = undefined };
    try std.testing.expectEqual(@as(c.gboolean, 0), closeDetachedPanelTab(@ptrCast(pending)));
}

test "many tiny assets wait for actual operation budget without reduced file caps" {
    try std.testing.expectEqual(ReadBudget.wait, nextReadBudget(0, assets.MAX_CONCURRENT_READS));
    try std.testing.expectEqual(ReadBudget.wait, nextReadBudget(1, assets.MAX_CONCURRENT_READS - 1));
    try std.testing.expectEqual(
        @as(usize, assets.MAX_ASSET_BYTES),
        nextReadBudget(2, assets.MAX_CONCURRENT_READS - 2).start,
    );

    // Simulate the full 64-asset operation. Every tiny completion releases
    // capacity, and no started read receives less than the 16 MiB file cap.
    var committed: u64 = 0;
    var completed: usize = 0;
    while (completed < assets.MAX_ASSETS_PER_OPERATION) {
        var active: usize = 0;
        while (completed + active < assets.MAX_ASSETS_PER_OPERATION and active < assets.MAX_CONCURRENT_READS) {
            switch (nextReadBudget(committed, active)) {
                .start => |budget| {
                    try std.testing.expectEqual(@as(usize, assets.MAX_ASSET_BYTES), budget);
                    active += 1;
                },
                .wait => break,
                .exhausted => return error.TestUnexpectedResult,
            }
        }
        try std.testing.expect(active > 0);
        committed += active;
        completed += active;
    }
    try std.testing.expectEqual(@as(u64, assets.MAX_ASSETS_PER_OPERATION), committed);
    try std.testing.expectEqual(ReadBudget.exhausted, nextReadBudget(assets.MAX_OPERATION_BYTES, 0));
    try std.testing.expectEqual(
        @as(usize, 7),
        nextReadBudget(assets.MAX_OPERATION_BYTES - 7, 0).start,
    );
}

test "panel cache decode runs off-caller and teardown discards its prepared result" {
    const a = std.heap.c_allocator;
    const usage_before = assets.processPreparedUsage();
    var root_buf: [160]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buf, "/tmp/sketerm-panel-decode-worker-{d}", .{c.getpid()});
    assets.removeTreeBestEffort(root);
    defer assets.removeTreeBestEffort(root);

    const rgba = [_]u8{ 0x20, 0x80, 0xff, 0xff } ** (8 * 8);
    const encoded = try @import("../util/png.zig").encodeRgba(a, &rgba, 8, 8);
    var drain = DrainHandle{};
    const job = try a.create(CacheJob);
    job.* = .{
        .drain = &drain,
        .pending_id = std.math.maxInt(u64),
        .asset_index = 0,
        .nonce = 1,
        .root = try a.dupe(u8, root),
        .bytes = encoded,
        .bytes_allocator = a,
        .protected = try a.alloc([64]u8, 0),
        .test_delay_ms = 150,
    };
    var done = std.atomic.Value(bool).init(false);
    const Runner = struct {
        fn main(cache_job: *CacheJob, finished: *std.atomic.Value(bool)) void {
            runCacheJob(cache_job);
            finished.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.main, .{ job, &done });
    while (!job.decode_started.load(.acquire)) _ = c.usleep(1_000);

    // The worker is deliberately inside decode preparation, yet the caller is
    // free to retire the DrainHandle rather than blocking like the old GTK path.
    try std.testing.expect(!done.load(.acquire));
    drain.alive.store(false, .release);
    thread.join();
    try std.testing.expect(job.ready.load(.acquire));
    try std.testing.expect(job.prepared != null);

    // No Hydration has this id, exactly as after origin teardown. The handback
    // must only release its owned pixbuf/blob/bytes and never dereference one.
    active_cache_jobs = 1;
    try std.testing.expectEqual(@as(c.gboolean, 0), cacheJobDone(@ptrCast(job)));
    try std.testing.expectEqual(@as(usize, 0), active_cache_jobs);
    try std.testing.expectEqual(usage_before, assets.processPreparedUsage());
}

test "hydration completion unlinks before reentrant reply backpressure cancellation" {
    const a = std.testing.allocator;
    hydrations = .empty;
    queued_panel_operations = .empty;
    panel_tab_jobs = .empty;
    defer {
        hydrations.deinit(a);
        queued_panel_operations.deinit(a);
        panel_tab_jobs.deinit(a);
        hydrations = .empty;
        queued_panel_operations = .empty;
        panel_tab_jobs = .empty;
    }

    var cache = try assets.Cache.initAt(a, "/tmp/sketerm-panel-reentrant-cache");
    defer cache.deinit();
    const previous_cache = panel_asset_cache;
    panel_asset_cache = &cache;
    defer panel_asset_cache = previous_cache;

    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_CLOEXEC, 0, &pair));
    defer _ = c.close(pair[1]);
    const predict = @import("../mux/predict.zig");
    var remote = Terminal.Remote{
        .conn = .{
            .allocator = a,
            .fd = pair[0],
            .panel_rpc = @import("../mux/wire.zig").PANEL_RPC_VERSION,
        },
        .session = @constCast("reentrant"),
        .origin_name = @constCast("reentrant"),
        .origin_id = @constCast("10000000000000000000000000000001"),
        .reconnect_job_active = true,
        .predictor = predict.Predictor.init(a),
    };
    defer remote.predictor.deinit();
    try remote.conn.wbuf.resize(a, mux_client.GUI_PANEL_REPLY_BACKLOG);

    const Pool = @import("../grid/style_pool.zig").Pool;
    const Screen = @import("../grid/screen.zig").Screen;
    var pool = try Pool.init(a);
    defer pool.deinit();
    const screen = try Screen.init(a, &pool, 2, 2);
    defer screen.deinit();
    var drain = DrainHandle{};
    var scope = RelayScope{
        .origin_id = "10000000000000000000000000000001".*,
    };
    var term: Terminal = undefined;
    term.allocator = a;
    term.remote = &remote;
    term.drain = &drain;
    term.screen = screen;
    term.on_render_request = null;
    term.on_connection_state = null;
    term.panel_scope_ctx = @ptrCast(&scope);
    const Cancel = struct {
        var calls: u32 = 0;
        fn run(terminal: *Terminal) void {
            calls += 1;
            cancelPanelWork(terminal);
        }
    };
    Cancel.calls = 0;
    term.on_panel_work_cancel = Cancel.run;
    drain.alive.store(true, .release);
    drain.terminal = &term;

    var window: Window = undefined;
    const pending = try a.create(Hydration);
    const asset_list = try a.alloc(HydrationAsset, 1);
    pending.* = .{
        .allocator = a,
        .id = 991,
        .relay_scope = &scope,
        .origin = &drain,
        .window = &window,
        .pane = null,
        .request_id = 77,
        // Completion parses this only after building its report. The invalid
        // request forces relayError, whose full reply queue loses transport.
        .request = try a.dupe(u8, "{"),
        .assets = asset_list,
        .read_source = .remote,
        .resolver = assets.Resolver.init(a, &cache),
        .deadline_ms = std.math.maxInt(i64),
    };
    asset_list[0] = .{
        .pending = pending,
        .logical = try a.dupe(u8, "/remote/failure.png"),
        .bytes_allocator = a,
        .state = .failed,
    };
    try hydrations.append(a, pending);

    completeHydration(pending);
    try std.testing.expectEqual(@as(u32, 1), Cancel.calls);
    try std.testing.expectEqual(@as(usize, 0), hydrations.items.len);
    try std.testing.expectEqual(@as(usize, 0), queued_panel_operations.items.len);
    try std.testing.expect(!remote.connected);
}

test "transport loss preserves direct local hydration and cancels relay work" {
    const a = std.testing.allocator;
    hydrations = .empty;
    queued_panel_operations = .empty;
    panel_tab_jobs = .empty;
    defer {
        hydrations.deinit(a);
        queued_panel_operations.deinit(a);
        panel_tab_jobs.deinit(a);
        hydrations = .empty;
        queued_panel_operations = .empty;
        panel_tab_jobs = .empty;
    }

    var remote = Terminal.Remote{
        .conn = .{ .allocator = a, .fd = -1 },
        .session = @constCast("reconnect"),
        .origin_name = @constCast("reconnect"),
        .panel_generation = 9,
        .predictor = undefined,
    };
    var drain = DrainHandle{};
    var scope = RelayScope{
        .origin_id = "11000000000000000000000000000001".*,
    };
    var term: Terminal = undefined;
    term.remote = &remote;
    term.drain = &drain;
    term.panel_scope_ctx = @ptrCast(&scope);
    drain.alive.store(true, .release);
    drain.terminal = &term;

    var job: PanelTabJob = undefined;
    job.scope = &scope;
    job.origin = &drain;
    job.generation = remote.panel_generation;
    job.canceled = .init(false);
    job.cancel_fd = .init(-1);
    try panel_tab_jobs.append(a, &job);
    const queued = try a.create(QueuedPanelOperation);
    queued.* = .{
        .allocator = a,
        .scope = &scope,
        .origin = &drain,
        .window = undefined,
        .pane = null,
        .request_id = 2,
        .request = try a.dupe(u8, "{}"),
        .deadline_ms = 10,
    };
    try queued_panel_operations.append(a, queued);
    const direct = try a.create(Hydration);
    direct.* = .{
        .allocator = a,
        .id = 44,
        .origin = &drain,
        .window = undefined,
        .pane = null,
        .request_id = 0,
        .request = try a.alloc(u8, 0),
        .assets = try a.alloc(HydrationAsset, 0),
        .read_source = .local,
        .resolver = assets.Resolver.init(a, null),
        .direct_panel_id = 88,
        .deadline_ms = std.math.maxInt(i64),
    };
    try hydrations.append(a, direct);

    // transportLost bumps first, then invokes cancelPanelWork. Reconnecting
    // makes canSend true again but cannot make the old generation committable.
    remote.panel_generation += 1;
    remote.connected = false;
    cancelPanelWork(&term);
    try std.testing.expect(assetOriginUsable(&drain));
    remote.connected = true;
    try std.testing.expect(job.canceled.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), queued_panel_operations.items.len);
    try std.testing.expectEqualSlices(*Hydration, &.{direct}, hydrations.items);
    try std.testing.expect(panelTabCommitTerminal(&job) == null);
    removePanelTabJob(&job);
    cancelTerminalPanelWork(&term, true);
    try std.testing.expectEqual(@as(usize, 0), hydrations.items.len);
    drain.panel_assets_live.store(false, .release);
    try std.testing.expect(!assetOriginUsable(&drain));
}

test "teardown fences and interrupts asynchronous panel tab setup" {
    var pair: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &pair));
    defer _ = c.close(pair[0]);
    defer _ = c.close(pair[1]);
    var job: PanelTabJob = undefined;
    job.canceled = .init(false);
    job.cancel_fd = .init(pair[0]);
    cancelPanelTab(&job);
    try std.testing.expect(job.canceled.load(.acquire));
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 0), c.read(pair[1], &byte, byte.len));
}

test "panel tab cancel duplicate cannot shutdown a reused worker fd" {
    var original: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &original));
    defer _ = c.close(original[1]);
    const worker_fd = original[0];
    const cancel_fd = c.fcntl(worker_fd, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
    try std.testing.expect(cancel_fd >= 0);
    defer _ = c.close(cancel_fd);

    // Reproduce the old race exactly: the worker closes its connection, then
    // another socket takes the same descriptor number before main cancels.
    _ = c.close(worker_fd);
    var replacement: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &replacement));
    defer _ = c.close(replacement[0]);
    defer _ = c.close(replacement[1]);
    try std.testing.expectEqual(worker_fd, replacement[0]);

    var job: PanelTabJob = undefined;
    job.canceled = .init(false);
    job.cancel_fd = .init(cancel_fd);
    cancelPanelTab(&job);

    var byte: u8 = 0x5a;
    try std.testing.expectEqual(@as(isize, 1), c.write(replacement[0], &byte, 1));
    byte = 0;
    try std.testing.expectEqual(@as(isize, 1), c.read(replacement[1], &byte, 1));
    try std.testing.expectEqual(@as(u8, 0x5a), byte);
    try std.testing.expectEqual(@as(isize, 0), c.read(original[1], &byte, 1));
}

test "panel open-session token cache coalesces and bounds completed retries" {
    const a = std.heap.c_allocator;
    var scope = RelayScope{ .origin_id = "10000000000000000000000000000001".* };
    defer {
        for (scope.open_session_tokens.items) |token| token.deinit();
        scope.open_session_tokens.deinit(a);
    }
    const first = try createOpenSessionToken(
        &scope,
        "first-token",
        "target",
        "20000000000000000000000000000002",
    );
    try std.testing.expectEqual(first, findOpenSessionToken(&scope, "first-token").?);
    try cacheOpenSessionReply(&scope, first, "{\"ok\":true,\"pane\":7}\n");
    try std.testing.expectEqualStrings("{\"ok\":true,\"pane\":7}\n", first.reply.?);

    for (0..MAX_OPEN_SESSION_COMPLETED) |i| {
        var token_buf: [32]u8 = undefined;
        const request_token = try std.fmt.bufPrint(&token_buf, "bounded-{d}", .{i});
        const token = try createOpenSessionToken(
            &scope,
            request_token,
            "target",
            "20000000000000000000000000000002",
        );
        try cacheOpenSessionReply(&scope, token, "{\"ok\":false,\"error\":\"done\"}\n");
    }
    try std.testing.expect(findOpenSessionToken(&scope, "first-token") == null);
    try std.testing.expectEqual(@as(usize, MAX_OPEN_SESSION_COMPLETED), scope.open_session_tokens.items.len);
    try std.testing.expect(findOpenSessionToken(&scope, "bounded-63") != null);
}

test "panel open-session cancel duplicate cannot shutdown a reused worker fd" {
    var original: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &original));
    defer _ = c.close(original[1]);
    const worker_fd = original[0];
    const cancel_fd = c.fcntl(worker_fd, c.F_DUPFD_CLOEXEC, @as(c_int, 3));
    try std.testing.expect(cancel_fd >= 0);
    defer _ = c.close(cancel_fd);
    _ = c.close(worker_fd);

    var replacement: [2]c_int = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &replacement));
    defer _ = c.close(replacement[0]);
    defer _ = c.close(replacement[1]);
    try std.testing.expectEqual(worker_fd, replacement[0]);

    var job: PanelOpenSessionJob = undefined;
    job.canceled = .init(false);
    job.cancel_fd = .init(cancel_fd);
    cancelPanelOpenSession(&job);

    var byte: u8 = 0x5a;
    try std.testing.expectEqual(@as(isize, 1), c.write(replacement[0], &byte, 1));
    byte = 0;
    try std.testing.expectEqual(@as(isize, 1), c.read(replacement[1], &byte, 1));
    try std.testing.expectEqual(@as(u8, 0x5a), byte);
    try std.testing.expectEqual(@as(isize, 0), c.read(original[1], &byte, 1));
}

test "panel reliable events retry acknowledge overflow and preserve legacy drain" {
    const a = std.testing.allocator;
    var queue = events.Queue.init();
    queue.push(events.Event.init("query", .submit, events.Value.fromText("draft")));
    queue.push(events.Event.init("ok", .click, .none));

    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(a);
    try writePanelEvents(&queue, TEST_EVENT_EPOCH, 0, true, &first, a);
    var retry: std.ArrayList(u8) = .empty;
    defer retry.deinit(a);
    try writePanelEvents(&queue, TEST_EVENT_EPOCH, 0, true, &retry, a);
    try std.testing.expectEqualStrings(first.items, retry.items);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, first.items, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        &TEST_EVENT_EPOCH,
        parsed.value.object.get("event_epoch").?.string,
    );
    const cursor: u64 = @intCast(parsed.value.object.get("cursor").?.integer);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.get("events").?.array.items.len);
    try std.testing.expectEqualStrings("draft", parsed.value.object.get("events").?.array.items[0].object.get("value").?.string);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("events").?.array.items[0].object.get("seq").?.integer);

    var acked: std.ArrayList(u8) = .empty;
    defer acked.deinit(a);
    try writePanelEvents(&queue, TEST_EVENT_EPOCH, cursor, true, &acked, a);
    var acked_parsed = try std.json.parseFromSlice(std.json.Value, a, acked.items, .{});
    defer acked_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), acked_parsed.value.object.get("events").?.array.items.len);
    try std.testing.expectEqual(@as(i64, @intCast(cursor)), acked_parsed.value.object.get("cursor").?.integer);

    var overflow = events.Queue.init();
    for (0..events.CAP + 2) |i| {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "e{d}", .{i});
        overflow.push(events.Event.init(id, .click, .none));
    }
    var overflow_out: std.ArrayList(u8) = .empty;
    defer overflow_out.deinit(a);
    try writePanelEvents(&overflow, TEST_EVENT_EPOCH, 0, true, &overflow_out, a);
    var overflow_parsed = try std.json.parseFromSlice(std.json.Value, a, overflow_out.items, .{});
    defer overflow_parsed.deinit();
    try std.testing.expectEqual(@as(i64, 2), overflow_parsed.value.object.get("dropped_total").?.integer);
    try std.testing.expectEqual(@as(usize, events.CAP), overflow_parsed.value.object.get("events").?.array.items.len);

    var legacy = events.Queue.init();
    legacy.push(events.Event.init("once", .click, .none));
    var drained: std.ArrayList(u8) = .empty;
    defer drained.deinit(a);
    try writePanelEvents(&legacy, TEST_EVENT_EPOCH, 0, false, &drained, a);
    var empty: std.ArrayList(u8) = .empty;
    defer empty.deinit(a);
    try writePanelEvents(&legacy, TEST_EVENT_EPOCH, 0, false, &empty, a);
    var empty_parsed = try std.json.parseFromSlice(std.json.Value, a, empty.items, .{});
    defer empty_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_parsed.value.object.get("events").?.array.items.len);
    try std.testing.expect(empty_parsed.value.object.get("cursor") == null);
    try std.testing.expect(empty_parsed.value.object.get("dropped") != null);

    var switched = events.Queue.init();
    switched.push(events.Event.init("old", .click, .none));
    var reliable_old: std.ArrayList(u8) = .empty;
    defer reliable_old.deinit(a);
    try writePanelEvents(&switched, TEST_EVENT_EPOCH, 0, true, &reliable_old, a);
    var reliable_parsed = try std.json.parseFromSlice(std.json.Value, a, reliable_old.items, .{});
    defer reliable_parsed.deinit();
    const old_cursor: u64 = @intCast(reliable_parsed.value.object.get("cursor").?.integer);
    var destructive: std.ArrayList(u8) = .empty;
    defer destructive.deinit(a);
    try writePanelEvents(&switched, TEST_EVENT_EPOCH, 0, false, &destructive, a);
    switched.push(events.Event.init("fresh", .click, .none));
    var after_switch: std.ArrayList(u8) = .empty;
    defer after_switch.deinit(a);
    try writePanelEvents(&switched, TEST_EVENT_EPOCH, old_cursor, true, &after_switch, a);
    var after_parsed = try std.json.parseFromSlice(std.json.Value, a, after_switch.items, .{});
    defer after_parsed.deinit();
    const switched_events = after_parsed.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), switched_events.len);
    try std.testing.expectEqualStrings("fresh", switched_events[0].object.get("component").?.string);
    try std.testing.expectEqual(@as(i64, 1), after_parsed.value.object.get("dropped_total").?.integer);
}

test "panel host epoch-fences acknowledgement before mixed reader mutation" {
    const a = std.testing.allocator;
    const saved_panels = panels;
    panels = .empty;
    defer {
        panels.deinit(a);
        panels = saved_panels;
    }
    var scope = RelayScope{ .origin_id = "30000000000000000000000000000003".* };
    var view = PanelView{
        .allocator = a,
        .asset_resolver = assets.Resolver.init(a, null),
        .queue = events.Queue.init(),
        .root_box = undefined,
        .scroller = undefined,
    };
    defer view.asset_resolver.deinit();
    var entry = Entry{
        .allocator = a,
        .panel_id = 901,
        .event_epoch = TEST_EVENT_EPOCH,
        .name = @constCast("mixed"),
        .session = @constCast("session"),
        .scope = .{ .relay = &scope },
        .target = .tab,
        .view = &view,
    };
    try panels.append(a, &entry);
    var window: Window = undefined;

    view.queue.push(events.Event.init("first", .click, .none));
    var discovery: std.ArrayList(u8) = .empty;
    defer discovery.deinit(a);
    try panelEvents(&window, .{
        .cmd = "panel-events-reliable",
        .panel_id = entry.panel_id,
        .ack = 0,
    }, &discovery, a, .{ .relay = &scope }, true);
    var discovered = try std.json.parseFromSlice(std.json.Value, a, discovery.items, .{});
    defer discovered.deinit();
    const cursor: u64 = @intCast(discovered.value.object.get("cursor").?.integer);

    var mismatch: std.ArrayList(u8) = .empty;
    defer mismatch.deinit(a);
    try panelEvents(&window, .{
        .cmd = "panel-events-reliable",
        .panel_id = entry.panel_id,
        .ack = cursor,
        .event_epoch = "20000000000000000000000000000002",
    }, &mismatch, a, .{ .relay = &scope }, true);
    try std.testing.expect(std.mem.indexOf(u8, mismatch.items, "\"error_code\":\"event_epoch_mismatch\"") != null);
    try std.testing.expectEqual(@as(usize, 1), view.queue.pending());

    var legacy: std.ArrayList(u8) = .empty;
    defer legacy.deinit(a);
    try panelEvents(&window, .{
        .cmd = "panel-events",
        .panel_id = entry.panel_id,
    }, &legacy, a, .{ .relay = &scope }, false);
    view.queue.push(events.Event.init("fresh", .click, .none));

    var retry: std.ArrayList(u8) = .empty;
    defer retry.deinit(a);
    try panelEvents(&window, .{
        .cmd = "panel-events-reliable",
        .panel_id = entry.panel_id,
        .ack = cursor,
        .event_epoch = &TEST_EVENT_EPOCH,
    }, &retry, a, .{ .relay = &scope }, true);
    var retried = try std.json.parseFromSlice(std.json.Value, a, retry.items, .{});
    defer retried.deinit();
    const retried_events = retried.value.object.get("events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), retried_events.len);
    try std.testing.expectEqualStrings("fresh", retried_events[0].object.get("component").?.string);
    try std.testing.expectEqual(@as(i64, 1), retried.value.object.get("dropped_total").?.integer);
    try std.testing.expect(retried.value.object.get("cursor").?.integer > @as(i64, @intCast(cursor)));
}

test "local panel reads enforce deadline byte and dimension bounds off GTK" {
    const a = std.testing.allocator;
    var path_buf: [160]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/sketerm-panel-local-bounds-{d}.png", .{c.getpid()});
    defer _ = c.unlink(path.ptr);

    const writeBytes = struct {
        fn run(file_path: [*:0]const u8, bytes: []const u8) !void {
            const fd = c.open(file_path, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c.mode_t, 0o600));
            if (fd < 0) return error.TestUnexpectedResult;
            defer _ = c.close(fd);
            if (c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len)))
                return error.TestUnexpectedResult;
        }
    }.run;

    try writeBytes(path.ptr, "small");
    const bytes = try readLocalAsset(a, std.mem.span(path.ptr), 8, std.math.maxInt(i64));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("small", bytes);
    try std.testing.expectError(error.Deadline, readLocalAsset(a, std.mem.span(path.ptr), 8, 0));

    try writeBytes(path.ptr, "ninebytes");
    try std.testing.expectError(error.TooBig, readLocalAsset(a, std.mem.span(path.ptr), 8, std.math.maxInt(i64)));

    const rgba = try a.alloc(u8, 9000 * 4);
    defer a.free(rgba);
    @memset(rgba, 0xff);
    const encoded = try @import("../util/png.zig").encodeRgba(a, rgba, 9000, 1);
    defer a.free(encoded);
    try writeBytes(path.ptr, encoded);
    try std.testing.expectError(error.Dimensions, decodeCachedImage(std.mem.span(path.ptr)));

    const small_rgba = [_]u8{ 0x20, 0x40, 0x80, 0xff } ** (8 * 8);
    const small_encoded = try @import("../util/png.zig").encodeRgba(a, &small_rgba, 8, 8);
    defer a.free(small_encoded);
    try writeBytes(path.ptr, small_encoded);
    // Reserve-before-decode against the real process budget: fill every
    // remaining pixel/byte so the header reservation itself must fail, and
    // prove the failed decode released nothing it did not own.
    const before = assets.processPreparedUsage();
    const full = assets.PreparedInfo{
        .pixels = assets.MAX_PROCESS_PREPARED_PIXELS,
        .bytes = assets.MAX_PROCESS_PREPARED_BYTES,
    };
    var blocker = try assets.ProcessPreparedReservation.reserve(.{
        .pixels = full.pixels - before.pixels,
        .bytes = full.bytes - before.bytes,
    });
    try std.testing.expectError(error.ProcessBudget, decodeCachedImage(std.mem.span(path.ptr)));
    try std.testing.expectEqual(full, assets.processPreparedUsage());
    blocker.release();

    var decoded = try decodeCachedImage(std.mem.span(path.ptr));
    try std.testing.expectEqual(before.pixels + decoded.reservation.info.pixels, assets.processPreparedUsage().pixels);
    try std.testing.expectEqual(before.bytes + decoded.reservation.info.bytes, assets.processPreparedUsage().bytes);
    c.g_object_unref(@ptrCast(decoded.pixbuf));
    decoded.reservation.release();
    try std.testing.expectEqual(before, assets.processPreparedUsage());
}

test "cache initialization worker handback discards results after origin teardown" {
    const allocator = std.heap.c_allocator;
    var drain = DrainHandle{};
    drain.alive.store(true, .release);
    var terminal: Terminal = undefined;
    drain.terminal = &terminal;
    const job = try allocator.create(CacheInitJob);
    job.* = .{
        .drain = &drain,
        .test_delay_ms = 120,
    };
    const Init = struct {
        fn run(a: std.mem.Allocator) !assets.Cache {
            return assets.Cache.initAt(a, "/tmp/sketerm-panel-cache-init-worker-test");
        }
    };
    var done = std.atomic.Value(bool).init(false);
    const Runner = struct {
        fn run(cache_job: *CacheInitJob, finished: *std.atomic.Value(bool)) void {
            runCacheInitJob(cache_job, Init.run);
            finished.store(true, .release);
        }
    };
    const thread = try std.Thread.spawn(.{}, Runner.run, .{ job, &done });
    _ = c.usleep(20_000);
    try std.testing.expect(!done.load(.acquire));
    drain.alive.store(false, .release);
    drain.terminal = null;
    thread.join();
    try std.testing.expect(job.cache != null);

    const previous_cache = panel_asset_cache;
    panel_asset_cache = null;
    cache_init_active = true;
    defer {
        panel_asset_cache = previous_cache;
        cache_init_active = false;
    }
    try std.testing.expectEqual(@as(c.gboolean, 0), cacheInitJobDone(@ptrCast(job)));
    try std.testing.expect(panel_asset_cache == null);
}
