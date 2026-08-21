//! Headless driver for `sketerm-webengine`: spawns and owns a private
//! browser helper and speaks the v1 wire protocol (src/web/protocol.zig)
//! as its one client, so the `web_*` MCP tools work with NO GUI at all.
//! The sibling of appdrive.zig in every respect: GTK-free, owns its
//! backend process, and every socket operation is non-blocking with a
//! deadline — a wedged helper costs one described error, never a hang.
//!
//! Views here are HELPER views, not GUI panes: there is no widget, no
//! tab and no user looking at them, and the views are windowless (OSR)
//! browsers with a software raster either way.
//!
//! ## The watchable web session
//!
//! Given a mux daemon socket (`Engine.init`'s `mux_sock` — the MCP
//! instance's private daemon), the engine first spawns a
//! Wayland-hosting mux app session named `web-<pid>-<nonce>` (the
//! `display create` machinery, `src/mux/display.zig`) and starts the
//! helper as a Wayland CLIENT of it: `SKETERM_WEB_OZONE=wayland` +
//! the session's environment, software rendering. The session is what
//! a human attaches to (`Session Overview`, or `sketerm mux
//! sock:<dir>/mux.sock attach <name>`): the assistant's browsing is a
//! session on a daemon instead of an invisible private process. What
//! that buys TODAY: page audio reaches the session's Pulse server (an
//! attached viewer hears it), the session is enumerable/attachable,
//! and its lifetime tracks the helper's. What it does NOT yet buy:
//! OSR browsers create no Wayland toplevels, so the session shows no
//! windows — window-level watch-along needs windowed browsers or a
//! presenter surface in the helper, on top of this seam.
//!
//! Session setup is best-effort with an automatic fallback: any
//! failure — no daemon, an old daemon, a helper that cannot even start
//! against the session's compositor — lands in the plain headless mode
//! that existed before (`--ozone-platform=headless`), and a
//! startup-with-session failure latches so the tools never flap.
//! `SKETERM_WEB_SESSION=0` opts out entirely. A leaked session (MCP
//! SIGKILL) is reaped by its own 60s no-client TTL.
//!
//! ## Discoverability
//!
//! The helper socket lives at the WELL-KNOWN name `web.sock` inside the
//! MCP instance directory (`$XDG_RUNTIME_DIR/sketerm/mcp-tmp-<pid>/` or
//! `mcp-<name>/`), next to a presence file `web.json`:
//!   {"mcp_pid":N,"helper_pid":N,"client":"sketerm-mcp[:name]","started_at_ms":N,
//!    "session":"web-...","mux_socket":"..."}
//! (the last two only in session mode) written when the helper comes up
//! and unlinked with it, so a GUI can enumerate assistant browser
//! sessions by scanning the instance dirs. NOTE for a frame-level "view
//! along": src/web/server.zig serves exactly ONE client and exits when
//! it disconnects — a second (viewer) client needs multi-client support
//! there first. This driver deliberately assumes nothing beyond "I
//! created my views": view ids are engine scoped, not connection
//! scoped.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const muxclient = @import("../mux/client.zig");
const display = @import("../mux/display.zig");
const proto = @import("../web/protocol.zig");
const reader_model = @import("../web/reader.zig");
const reader_guards = @import("../web/reader_guards.zig");
const findbin = @import("../web/findbin.zig");
const png = @import("../util/png.zig");
const quarantine = @import("../web/quarantine.zig");
const clock = @import("../util/clock.zig");
const webprofiles = @import("webprofiles.zig");
const netpolicy = @import("../web/netpolicy.zig");

/// Default logical size a headless view is created at. There is no
/// allocation to inherit one from, and pages lay out sanely at a
/// laptop-ish viewport.
pub const DEFAULT_W: u16 = 1280;
pub const DEFAULT_H: u16 = 800;

/// How long a freshly spawned helper gets to bind its socket. CEF's
/// startup (re-exec, zygote) dominates; matches the GUI's 150x100ms.
const SPAWN_WAIT_MS: i64 = 15_000;

/// How long teardown waits for the helper to exit on its own after its
/// socket closes, before signalling. That self-exit runs `cef_shutdown`,
/// which is the only thing that flushes a persistent profile's cookies;
/// CEF usually takes a few hundred ms.
const GRACEFUL_EXIT_MS: u32 = 4_000;

/// Deadline for one bounded send. The helper drains its socket in its
/// poll loop; a peer that takes longer than this is wedged.
const SEND_TIMEOUT_MS: i64 = 5_000;

/// Mirrors the GUI face's install message; the helper is opt-in.
pub const MISSING_MSG =
    "the browser helper (sketerm-webengine) is not installed. It is opt-in because it needs a CEF binary distribution: build it with `zig build fetch-cef && zig build web` (or install the sketerm package, which ships it)";

pub const LOST_MSG = "the browser helper stopped (it is restarted on the next web tool call)";

pub const OpKind = enum(u3) { snapshot, act, expand, query, read, eval };

const N_KINDS = 6;

/// One semantic request, engine-agnostic. Byte fields carry the wire
/// enums from protocol.zig.
pub const OpReq = struct {
    kind: OpKind,
    mode: u8 = 0,
    detail: u8 = 1,
    scope: u32 = 0,
    id: u32 = 0,
    action: u8 = 0,
    arg: []const u8 = "",
    off: u32 = 0,
    len: u32 = 4096,
    flags: u8 = 0,
    timeout_ms: u32 = 10_000,
};

/// One finished round trip; `text` is arena-owned by the caller.
pub const OpOut = struct {
    ok: bool = false,
    text: []const u8 = "",
    doc_gen: u32 = 0,
    rev: u32 = 0,
    snap_kind: u8 = 0,
    timed_out: bool = false,
};

/// A completed reply parked until the in-flight runOp collects it.
const Sem = struct {
    ok: bool,
    text: []u8,
    doc_gen: u32 = 0,
    rev: u32 = 0,
    snap_kind: u8 = 0,
};

pub const View = struct {
    id: u32,
    w: u16,
    h: u16,
    /// Identity context this view lives in; 0 = the shared default jar
    /// (in-memory, dies with the helper).
    context: u32 = 0,
    /// Named persistent profile, when the view was opened in one; owned.
    profile: ?[]u8 = null,
    /// The context is a throwaway one, destroyed with the last view
    /// using it.
    ephemeral_ctx: bool = false,
    /// The helper refused to create this view because its context was
    /// unavailable (`ev_view_create_failed`, the ONLY creation-failure
    /// signal — `context_create` has no ack). Owned.
    create_failed: ?[]u8 = null,
    url: ?[]u8 = null,
    title: ?[]u8 = null,
    loading: bool = false,
    can_back: bool = false,
    can_fwd: bool = false,
    /// Main-frame load-finished counter; a settle waits on this, not on
    /// a paint (a queued repaint of the PREVIOUS page satisfies a paint
    /// wait instantly).
    load_seq: u32 = 0,

    // Last software frame. FRAME DELIVERY SEAM: this driver receives
    // pixels ONLY as an shm memfd (`frames-shm`; headless ozone spawns
    // no GPU, so `frames-dmabuf` never applies), and every fd/mmap
    // assumption lives in these four fields, the `.frame_buffer`
    // dispatch arm and `screenshotPng`. A future inline-bytes frame
    // family (needed once frames must cross a mux relay, where fds
    // cannot travel) is a new arm filling the same fields' role, not a
    // rewrite of this module.
    buf_fd: c_int = -1,
    buf_w: u16 = 0,
    buf_h: u16 = 0,
    buf_stride: u32 = 0,
    /// Paint counter; a screenshot briefly waits for it to move so a
    /// just-acted-on page is photographed after the repaint.
    frame_gen: u32 = 0,

    // Semantic bookkeeping. This driver is called synchronously, so a
    // parked reply per kind suffices; request ids reject late replies
    // from abandoned calls. Legacy helpers permit one op per kind.
    inbox: [N_KINDS]?Sem = @splat(null),
    waiting: [N_KINDS]bool = @splat(false),
    waiting_request: [N_KINDS]u32 = @splat(0),
    /// Legacy replies have no request id. After a client timeout, one
    /// late reply must be consumed before that kind can be reused.
    legacy_quarantine: quarantine.LegacyQuarantine(N_KINDS) = .{},
    /// A mode:full snapshot is not satisfied by a delta (a stray push
    /// from a pre-coalescing helper).
    want_full: bool = false,
    /// The full text of the last eval result (what `web_expand [0]`
    /// pages), mirroring the GUI face.
    last_eval: ?[]u8 = null,
    /// Every ID ever returned by rich reader mode on this helper view.
    /// New reads refresh matching guards and invalidate absent ones;
    /// unrelated snapshots never erase the ID's reader provenance.
    reader_guards: reader_guards.Store = .{},

    // Request interception (capability "intercept"). Counters come from
    // `intercept_status`; the log is PULLED on demand (`intercept_log`),
    // never streamed, per the MCP backlog rule.
    net_enabled: bool = true,
    net_blocked: u32 = 0,
    net_total: u32 = 0,
    net_rules: u32 = 0,
    /// Next seq to pull; advances as the log is drained.
    net_next_seq: u32 = 0,
    /// A parked `intercept_log` reply (owned JSON), awaited by
    /// `networkLog`.
    net_log: ?[]u8 = null,
    net_log_waiting: bool = false,

    // Enforced network policy (capability "net-policy"). The policy the
    // view was opened with (owned strings) plus the accounting mirror
    // `ev_net_policy` keeps fresh.
    pol: ?NetPolicy = null,
    pol_serial: u32 = 0,
    pol_active: bool = false,
    /// The helper answered `active=0` for our serial: the install was
    /// refused (its slot table is full). The open must fail closed.
    pol_install_failed: bool = false,
    /// `proto.NetReason` byte; nonzero once a budget latched.
    pol_exhausted: u8 = 0,
    pol_requests: u32 = 0,
    pol_bytes: u64 = 0,
    pol_navigations: u32 = 0,
    pol_ms_left: u32 = 0,
    pol_denied: [proto.NREASONS]u32 = @splat(0),

    fn deinit(self: *View, gpa: std.mem.Allocator) void {
        if (self.url) |u| gpa.free(u);
        if (self.title) |t| gpa.free(t);
        if (self.profile) |p| gpa.free(p);
        if (self.create_failed) |f| gpa.free(f);
        if (self.last_eval) |e| gpa.free(e);
        if (self.pol) |*p| freePolicy(gpa, p);
        self.reader_guards.deinit(gpa);
        if (self.net_log) |e| gpa.free(e);
        if (self.buf_fd >= 0) _ = c.close(self.buf_fd);
        for (&self.inbox) |*slot| {
            if (slot.*) |s| gpa.free(s.text);
            slot.* = null;
        }
    }
};

pub const State = enum { idle, ready, unavailable };

/// The Wayland-hosting mux session the helper renders into, plus the
/// daemon connection that created it (kept for the origin-fenced
/// destroy at teardown).
const WebSession = struct {
    conn: muxclient.Conn,
    created: display.Created,
};

/// NUL-terminated copies of a session's environment, prepared BEFORE
/// fork (no allocation between fork and exec).
const SessionEnv = struct {
    wl: [4096:0]u8 = undefined,
    rt: [4096:0]u8 = undefined,
    pulse: [4200:0]u8 = undefined,
    have_rt: bool = false,
    have_pulse: bool = false,
    active: bool = false,
};

/// Which identity a view is opened in. `.default` is byte-for-byte
/// today's behaviour: context 0, the helper's shared in-memory jar.
pub const ProfileSpec = union(enum) { default, named: []const u8, ephemeral };

/// Every way a profile request can be refused BEFORE anything is
/// opened. There is deliberately no shared-jar fallback: a caller that
/// asked for an isolated identity and silently got the shared one would
/// be leaking a login into it.
pub const ProfileError = error{
    ContextsUnsupported,
    StoreUnavailable,
    InvalidName,
    StoreIo,
    InUse,
    NoProfile,
};

/// An ENFORCED network policy as the client speaks it: what `web_open`
/// parsed, what a profile default stores, and what `net_policy_set`
/// serializes. Field semantics live in `web/netpolicy.zig` (the
/// decision home); this is the transportable value.
pub const NetPolicy = struct {
    allow_top: []const []const u8 = &.{},
    allow_sub: []const []const u8 = &.{},
    block_types: u16 = 0,
    allow_schemes: u16 = netpolicy.default_schemes,
    allow_private: bool = false,
    /// Tri-state sugar over the EasyList shield's per-view switch:
    /// null leaves it alone (it defaults ON process-wide).
    block_ads: ?bool = null,
    max_requests: u32 = 0,
    max_bytes: u64 = 0,
    max_navigations: u32 = 0,
    deadline_ms: u32 = 0,
};

/// A policy as a CLIENT WROTE it: every field remembers whether it was
/// supplied. `effective()` fills the open-time defaults for a fresh
/// policy; `tightenViewPolicy` reads presence directly, so an omitted
/// field can never be mistaken for a request to tighten to its default
/// (the way a bare `NetPolicy{}` once reset a live view's schemes to
/// http+https and its allow_private to off). Host lists and block_types
/// keep "empty = nothing said" — an empty allow-list could not mean
/// anything else at tighten time, and there is no type to un-block.
pub const NetPolicyPatch = struct {
    allow_top: []const []const u8 = &.{},
    allow_sub: []const []const u8 = &.{},
    block_types: u16 = 0,
    allow_schemes: ?u16 = null,
    allow_private: ?bool = null,
    block_ads: ?bool = null,
    max_requests: ?u32 = null,
    max_bytes: ?u64 = null,
    max_navigations: ?u32 = null,
    deadline_ms: ?u32 = null,

    /// The full policy a fresh view or a profile default gets from this
    /// patch: omitted fields take `NetPolicy`'s defaults.
    pub fn effective(self: NetPolicyPatch) NetPolicy {
        return .{
            .allow_top = self.allow_top,
            .allow_sub = self.allow_sub,
            .block_types = self.block_types,
            .allow_schemes = self.allow_schemes orelse netpolicy.default_schemes,
            .allow_private = self.allow_private orelse false,
            .block_ads = self.block_ads,
            .max_requests = self.max_requests orelse 0,
            .max_bytes = self.max_bytes orelse 0,
            .max_navigations = self.max_navigations orelse 0,
            .deadline_ms = self.deadline_ms orelse 0,
        };
    }
};

/// Every way a POLICIED open can be refused before anything opens.
/// Same fail-closed contract as `ProfileError`: no unpoliced fallback.
pub const NetPolicyError = error{
    PolicyUnsupported,
    PolicyTooManyViews,
    NoPolicy,
};

/// Deep-copy a policy so a stored one outlives its caller's arena.
fn dupePolicy(gpa: std.mem.Allocator, p: NetPolicy) !NetPolicy {
    var out = p;
    out.allow_top = try dupeHostList(gpa, p.allow_top);
    errdefer freeHostList(gpa, out.allow_top);
    out.allow_sub = try dupeHostList(gpa, p.allow_sub);
    return out;
}

fn freePolicy(gpa: std.mem.Allocator, p: *NetPolicy) void {
    freeHostList(gpa, p.allow_top);
    freeHostList(gpa, p.allow_sub);
    p.allow_top = &.{};
    p.allow_sub = &.{};
}

fn dupeHostList(gpa: std.mem.Allocator, hosts: []const []const u8) ![]const []const u8 {
    if (hosts.len == 0) return &.{};
    const out = try gpa.alloc([]const u8, hosts.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |h| gpa.free(h);
        gpa.free(out);
    }
    for (hosts) |h| {
        out[n] = try gpa.dupe(u8, h);
        n += 1;
    }
    return out;
}

fn freeHostList(gpa: std.mem.Allocator, hosts: []const []const u8) void {
    for (hosts) |h| gpa.free(h);
    if (hosts.len > 0) gpa.free(hosts);
}

/// One identity context PUBLISHED to the running helper.
const LiveCtx = struct {
    id: u32,
    /// Profile name for a persistent context; empty for an ephemeral
    /// one. Owned when non-empty.
    name: []u8,
    ephemeral: bool,
    /// Helper generation this was last `context_create`d into; a helper
    /// restart makes it stale and the next open republishes the SAME id.
    published_gen: u32 = 0,
    views: u32 = 0,
};

pub const Engine = struct {
    gpa: std.mem.Allocator,
    /// Directory holding the helper socket and its cache; owned.
    dir: []u8,
    /// MCP instance name (`--name work`), which keys the profile store
    /// root; owned, null for an anonymous instance.
    instance: ?[]u8 = null,
    /// Hello identity ("sketerm-mcp" or "sketerm-mcp:<instance>"), so
    /// helper logs and a future viewer can attribute the session to an
    /// assistant rather than an anonymous client. Owned.
    client_name: []u8,
    /// Mux daemon socket for the watchable web session; null disables
    /// session hosting outright. Owned.
    mux_sock: ?[]u8 = null,
    session: ?WebSession = null,
    /// Latched when a helper failed to START with the session
    /// environment: later spawns go plain headless instead of paying a
    /// doomed session + spawn per tool call.
    session_blocked: bool = false,
    state: State = .idle,
    /// Why `state == .unavailable`. Static strings only.
    reason: []const u8 = "",
    /// False for "not installed", where a retry can only fail the same
    /// way; true for anything a restart might fix.
    retryable: bool = true,
    pid: c.pid_t = -1,
    fd: c_int = -1,
    in: std.ArrayList(u8) = .empty,
    /// Descriptors received through SCM_RIGHTS, in arrival order; a
    /// `frame_buffer` frame pops the front one.
    rx_fds: std.ArrayList(c_int) = .empty,
    next_view: u32 = 1,
    views: std.ArrayList(*View) = .empty,
    /// The view a handle-less tool call means. Headless has no window
    /// manager to own focus, so "current" is last-touched: opening or
    /// addressing a view makes it current. Without this the fallback
    /// was the OLDEST view, so a second `web_open` returned a correctly
    /// navigated view that every following call then ignored — which
    /// reads exactly like `web_open` dropping its url.
    current: u32 = 0,
    cap_shm: bool = false,
    cap_semantic: bool = false,
    cap_reader_ids: bool = false,
    cap_semantic_request_ids: bool = false,
    /// The helper can create a view directly at a url, so a view opened
    /// with one never holds a blank document first.
    cap_view_url: bool = false,
    /// The helper runs the in-process content-blocking filter engine.
    cap_intercept: bool = false,
    /// The helper accepts identity contexts...
    cap_contexts: bool = false,
    /// ...and REFUSES a view whose context does not exist rather than
    /// silently resolving it through the shared jar. Profiles require
    /// both: without the second one a refused context is invisible.
    cap_contexts_fail_closed: bool = false,
    /// The helper enforces per-view network policy (0x86 block).
    cap_net_policy: bool = false,
    next_sem_request: u32 = 1,
    /// Stamps every `net_policy_set`; `ev_net_policy` echoes it so a
    /// stale event for a replaced policy is ignorable.
    next_policy_serial: u32 = 1,
    /// Session defaults per profile NAME, applied by `openViewIn` when
    /// the caller names the profile and passes no explicit policy.
    /// Deliberately NOT persisted: the store's corrupt-rebuild path
    /// would otherwise be a silent-loosening hole. Keys and host lists
    /// owned.
    profile_policy: std.StringHashMapUnmanaged(NetPolicy) = .empty,

    /// Durable profile store; null when it could not be taken (see
    /// `store_reason`). Opened lazily, ONCE per engine — a store that
    /// appeared after the helper already started with the volatile
    /// cache dir would name jars the running helper cannot reach.
    store: ?webprofiles.Store = null,
    store_tried: bool = false,
    /// Why there is no store. Static strings, or one arena-free owned
    /// sentence for the lock case; owned when `store_reason_owned`.
    store_reason: []const u8 = "",
    store_reason_owned: bool = false,
    /// Contexts published to the CURRENT helper.
    live: std.ArrayList(LiveCtx) = .empty,
    /// Ephemeral ids live above every persisted one, so the two spaces
    /// can never meet.
    next_eph: u32 = webprofiles.EPHEMERAL_BASE,
    /// Bumped by every successful helper start, so "was this context
    /// published to the helper that is running NOW" is derivable.
    helper_gen: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, dir: []const u8, instance: ?[]const u8, mux_sock: ?[]const u8) !Engine {
        const owned_dir = try gpa.dupe(u8, dir);
        errdefer gpa.free(owned_dir);
        const name = if (instance) |n|
            try std.fmt.allocPrint(gpa, "sketerm-mcp:{s}", .{n})
        else
            try gpa.dupe(u8, "sketerm-mcp");
        errdefer gpa.free(name);
        const owned_instance: ?[]u8 = if (instance) |n| try gpa.dupe(u8, n) else null;
        errdefer if (owned_instance) |n| gpa.free(n);
        const owned_sock: ?[]u8 = if (mux_sock) |sck| try gpa.dupe(u8, sck) else null;
        return .{
            .gpa = gpa,
            .dir = owned_dir,
            .instance = owned_instance,
            .client_name = name,
            .mux_sock = owned_sock,
        };
    }

    /// Kill and reap the helper; safe to call from a signal-driven
    /// teardown path (the helper also exits on its own when this
    /// process's socket closes).
    pub fn deinit(self: *Engine) void {
        self.dropConnection();
        if (self.pid > 0) {
            var status: c_int = 0;
            // Let the helper exit ON ITS OWN first. The closed socket is
            // its exit signal, and the clean path it then runs (close
            // every browser, `cef_shutdown`) is what FLUSHES a profile's
            // cookies to disk. Signalling here instead cost every named
            // profile the session that had just been written into it —
            // the jar was durable and always came back empty.
            var tries: u32 = 0;
            var reaped = false;
            while (tries < GRACEFUL_EXIT_MS / 20) : (tries += 1) {
                if (c.waitpid(self.pid, &status, c.WNOHANG) == self.pid) {
                    reaped = true;
                    break;
                }
                _ = c.usleep(20_000);
            }
            if (!reaped) {
                _ = c.kill(self.pid, c.SIGTERM);
                tries = 0;
                while (tries < 40) : (tries += 1) {
                    if (c.waitpid(self.pid, &status, c.WNOHANG) == self.pid) break;
                    _ = c.usleep(50_000);
                }
                if (tries >= 40) {
                    _ = c.kill(self.pid, c.SIGKILL);
                    _ = c.waitpid(self.pid, &status, 0);
                }
            }
            self.pid = -1;
        }
        self.removePresence();
        // After the helper: its Wayland connection must be gone before
        // the session's socket goes away under it.
        self.teardownSession(true);
        if (self.mux_sock) |sck| {
            self.gpa.free(sck);
            self.mux_sock = null;
        }
        self.clearViews();
        self.views.deinit(self.gpa);
        self.in.deinit(self.gpa);
        self.rx_fds.deinit(self.gpa);
        // Persistent contexts are deliberately NEVER destroyed at
        // shutdown: killing the helper flushes their jars, while racing
        // a context_destroy against the kill risks a half-written one.
        self.clearContexts();
        self.live.deinit(self.gpa);
        var pit = self.profile_policy.iterator();
        while (pit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            freePolicy(self.gpa, entry.value_ptr);
        }
        self.profile_policy.deinit(self.gpa);
        // The flock goes only after the helper is reaped, or a
        // successor could take the root while CEF still holds it open.
        if (self.store) |*s| {
            s.deinit();
            self.store = null;
        }
        self.clearStoreReason();
        if (self.instance) |n| self.gpa.free(n);
        self.instance = null;
        self.gpa.free(self.dir);
        self.gpa.free(self.client_name);
        self.state = .idle;
    }

    fn clearContexts(self: *Engine) void {
        for (self.live.items) |ctx| {
            if (ctx.name.len > 0) self.gpa.free(ctx.name);
        }
        self.live.clearRetainingCapacity();
    }

    fn clearStoreReason(self: *Engine) void {
        if (self.store_reason_owned) self.gpa.free(@constCast(self.store_reason));
        self.store_reason = "";
        self.store_reason_owned = false;
    }

    fn setStoreReason(self: *Engine, reason: []const u8, owned: bool) void {
        self.clearStoreReason();
        self.store_reason = reason;
        self.store_reason_owned = owned;
    }

    /// Take the durable profile store, once. Failure is not fatal: the
    /// engine keeps its volatile cache dir and every profile request is
    /// refused with `store_reason`.
    fn openStore(self: *Engine) void {
        if (self.store_tried) return;
        self.store_tried = true;
        var holder: c.pid_t = 0;
        self.store = webprofiles.Store.open(self.gpa, self.instance, &holder) catch |err| {
            switch (err) {
                error.Locked => {
                    const msg = std.fmt.allocPrint(
                        self.gpa,
                        "another sketerm mcp process (pid {d}) owns the browser profile store; run this one with --name <something> to give it a store of its own",
                        .{holder},
                    ) catch {
                        self.setStoreReason("another sketerm mcp process owns the browser profile store; run this one with --name <something>", false);
                        return;
                    };
                    self.setStoreReason(msg, true);
                },
                error.NoStateDir => self.setStoreReason("no state directory to keep browser profiles in (neither XDG_STATE_HOME nor HOME is set)", false),
                error.PathTooLong => self.setStoreReason("the browser profile store path is too long for the browser helper's cache-path limit (use a shorter XDG_STATE_HOME)", false),
                error.Io, error.OutOfMemory => self.setStoreReason("the browser profile store could not be created (check permissions on XDG_STATE_HOME/sketerm)", false),
            }
            return;
        };
        self.clearStoreReason();
    }

    /// Name of the live watchable Wayland session the helper was
    /// started against; null in plain headless mode.
    pub fn sessionName(self: *const Engine) ?[]const u8 {
        if (self.session) |*s| return s.created.name;
        return null;
    }

    fn sessionWanted(self: *const Engine) bool {
        if (self.mux_sock == null or self.session_blocked) return false;
        const v = c.getenv("SKETERM_WEB_SESSION") orelse return true;
        const s = std.mem.span(v);
        return !(std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "no"));
    }

    /// Create (or verify) the web session. Best effort: on any failure
    /// the engine simply stays in plain headless mode.
    fn ensureSession(self: *Engine) void {
        if (!self.sessionWanted()) return;
        if (self.session) |*s| {
            // A daemon restart takes the session's display socket with
            // it; a stale one must not be exported to a fresh helper.
            var z: [4096:0]u8 = undefined;
            const p = std.fmt.bufPrintZ(&z, "{s}", .{s.created.wl_display}) catch return;
            if (c.access(p.ptr, c.F_OK) == 0) return;
            self.teardownSession(false);
        }
        var conn = muxclient.Conn.connectLocalAutostartAt(self.gpa, self.mux_sock) catch return;
        var nonce: [4]u8 = undefined;
        if (c.getentropy(&nonce, nonce.len) != 0) std.mem.writeInt(u32, &nonce, @bitCast(c.getpid()), .little);
        var name_buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "web-{d}-{x}", .{
            c.getpid(), std.mem.readInt(u32, &nonce, .little),
        }) catch unreachable;
        // No Xwayland (the helper is a native Wayland client), software
        // GL, and a short TTL as the orphan backstop: with no attached
        // viewer and no live Wayland client the daemon reaps it.
        const created = display.spawnSession(self.gpa, &conn, .{
            .xwayland = .disabled,
            .ttl_secs = 60,
        }, name) orelse {
            conn.deinit();
            return;
        };
        self.session = .{ .conn = conn, .created = created };
    }

    fn teardownSession(self: *Engine, destroy: bool) void {
        if (self.session) |*s| {
            if (destroy) _ = display.destroySession(
                self.gpa,
                &s.conn,
                s.created.name,
                &s.created.origin_id,
                s.created.pid,
                s.created.wl_display,
            );
            s.conn.deinit();
            s.created.deinit();
            self.session = null;
        }
    }

    /// Snapshot the session's environment into fork-safe buffers.
    fn sessionEnv(self: *const Engine) SessionEnv {
        var env = SessionEnv{};
        const s: *const WebSession = if (self.session) |*sp| sp else return env;
        _ = std.fmt.bufPrintZ(&env.wl, "{s}", .{s.created.wl_display}) catch return env;
        if (s.created.runtime_dir.len > 0) {
            _ = std.fmt.bufPrintZ(&env.rt, "{s}", .{s.created.runtime_dir}) catch return env;
            env.have_rt = true;
        }
        if (s.created.pulse_server.len > 0) {
            if (std.fmt.bufPrintZ(&env.pulse, "unix:{s}", .{s.created.pulse_server})) |_| {
                env.have_pulse = true;
            } else |_| {}
        }
        env.active = true;
        return env;
    }

    /// Write `web.json` next to the socket (see the header). Best
    /// effort: enumeration metadata, never load-bearing.
    fn writePresence(self: *Engine) void {
        var path_z: [4096:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&path_z, "{s}/web.json", .{self.dir}) catch return;
        const f = c.fopen(p.ptr, "w") orelse return;
        defer _ = c.fclose(f);
        var line: [8704]u8 = undefined;
        var len: usize = 0;
        len += (std.fmt.bufPrint(line[len..], "{{\"mcp_pid\":{d},\"helper_pid\":{d},\"client\":\"{s}\",\"started_at_ms\":{d}", .{
            c.getpid(), self.pid, self.client_name, clock.nowMs(),
        }) catch return).len;
        if (self.session) |*ws| {
            // Session name + daemon socket contain no JSON specials
            // (daemon-validated name, filesystem path we minted).
            len += (std.fmt.bufPrint(line[len..], ",\"session\":\"{s}\",\"mux_socket\":\"{s}\"", .{
                ws.created.name, self.mux_sock.?,
            }) catch return).len;
        }
        len += (std.fmt.bufPrint(line[len..], "}}\n", .{}) catch return).len;
        _ = c.fwrite(&line, 1, len, f);
    }

    fn removePresence(self: *Engine) void {
        var path_z: [4096:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&path_z, "{s}/web.json", .{self.dir}) catch return;
        _ = c.unlink(p.ptr);
    }

    /// The live socket fd, for the central MCP watchdog; -1 when none.
    pub fn watchdogFd(self: *const Engine) c_int {
        return self.fd;
    }

    fn clearViews(self: *Engine) void {
        for (self.views.items) |v| {
            v.deinit(self.gpa);
            self.gpa.destroy(v);
        }
        self.views.clearRetainingCapacity();
    }

    fn dropConnection(self: *Engine) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        for (self.rx_fds.items) |fd| _ = c.close(fd);
        self.rx_fds.clearRetainingCapacity();
        self.in.clearRetainingCapacity();
    }

    /// The connection died (helper crash or protocol error): reap,
    /// drop views (a fresh helper knows no ids), stay retryable.
    fn lost(self: *Engine) void {
        self.dropConnection();
        if (self.pid > 0) {
            var status: c_int = 0;
            _ = c.waitpid(self.pid, &status, c.WNOHANG);
            self.pid = -1;
        }
        self.clearViews();
        // Every published context died with the helper. Persistent ids
        // are safe in the store, so the next open republishes the SAME
        // id and lands in the SAME jar; ephemeral ones are simply gone.
        self.clearContexts();
        self.cap_shm = false;
        self.cap_semantic = false;
        self.cap_reader_ids = false;
        self.cap_semantic_request_ids = false;
        self.cap_view_url = false;
        self.cap_intercept = false;
        self.cap_contexts = false;
        self.cap_contexts_fail_closed = false;
        self.cap_net_policy = false;
        self.removePresence();
        self.state = .unavailable;
        self.reason = LOST_MSG;
        self.retryable = true;
    }

    /// Bring the helper up if it is not already. Bounded: a missing
    /// binary or a helper that never binds leaves `.unavailable` with
    /// `reason` set, and the caller reports that instead of hanging.
    pub fn ensure(self: *Engine) bool {
        // Before anything else, and exactly once: the store root IS the
        // helper's --cache-dir, so the decision has to be made before a
        // helper exists and must never change under a running one.
        self.openStore();
        if (self.state == .ready) {
            // A helper that died between calls reads as EOF here.
            if (!self.readAvailable()) return self.state == .ready;
            return true;
        }
        if (self.state == .unavailable) {
            if (!self.retryable) return false;
            self.state = .idle;
        }

        var bin_buf: [4096:0]u8 = undefined;
        const bin = findbin.find(&bin_buf) orelse {
            self.state = .unavailable;
            self.reason = MISSING_MSG;
            self.retryable = false;
            return false;
        };

        var dir_z: [4096:0]u8 = undefined;
        const dz = std.fmt.bufPrintZ(&dir_z, "{s}", .{self.dir}) catch return self.failStart("helper directory path too long");
        _ = c.mkdir(dz.ptr, 0o700);
        var sock_z: [108:0]u8 = undefined;
        const sock = std.fmt.bufPrintZ(&sock_z, "{s}/web.sock", .{self.dir}) catch
            return self.failStart("helper socket path exceeds the unix socket limit (use a shorter runtime dir)");
        // The helper's --cache-dir IS its `root_cache_path`, and CEF
        // demands every persistent context's jar be a child of it — so
        // the durable profile store root has to BE that dir. Without a
        // store the old volatile dir stays, and profiles stay refused.
        var cache_z: [4096:0]u8 = undefined;
        if (self.store) |*s| {
            _ = std.fmt.bufPrintZ(&cache_z, "{s}", .{s.root}) catch return self.failStart("helper cache path too long");
        } else {
            _ = std.fmt.bufPrintZ(&cache_z, "{s}/web-cache", .{self.dir}) catch return self.failStart("helper cache path too long");
        }

        // Watchable session first (best effort); the helper is then
        // started as that session's Wayland client.
        self.ensureSession();
        if (self.startHelper(bin, sock, &sock_z, &cache_z)) return true;

        // A helper that cannot even start against the session's
        // compositor must not cost the web tools: drop the session,
        // latch, and retry once in the plain headless mode.
        if (self.session != null) {
            self.teardownSession(true);
            self.session_blocked = true;
            const note = "sketerm mcp: web helper failed to start in session mode; retrying plain headless\n";
            _ = c.write(2, note, note.len);
            if (self.state == .unavailable and self.retryable) self.state = .idle;
            return self.startHelper(bin, sock, &sock_z, &cache_z);
        }
        return false;
    }

    /// One spawn + connect + handshake attempt. On success the engine
    /// is `.ready` with the presence file written.
    fn startHelper(self: *Engine, bin: [*:0]const u8, sock: [:0]const u8, sock_z: *[108:0]u8, cache_z: *[4096:0]u8) bool {
        // A stale socket from a crashed helper would make the connect
        // succeed against nothing.
        _ = c.unlink(sock.ptr);
        const env = self.sessionEnv();

        const pid = c.fork();
        if (pid == 0) {
            // stdin/stdout to /dev/null; stderr stays (CEF refusals
            // land there, next to the MCP server's own log).
            const devnull = c.open("/dev/null", c.O_RDWR);
            if (devnull >= 0) {
                _ = c.dup2(devnull, 0);
                _ = c.dup2(devnull, 1);
                if (devnull > 2) _ = c.close(devnull);
            }
            if (env.active) {
                // The session's display, software rendering. The exact
                // env recipe is display.zig's `run` (never derive wl-*
                // paths; the daemon returned these).
                _ = c.setenv("WAYLAND_DISPLAY", &env.wl, 1);
                if (env.have_rt) _ = c.setenv("XDG_RUNTIME_DIR", &env.rt, 1);
                _ = c.setenv("XDG_SESSION_TYPE", "wayland", 1);
                if (env.have_pulse) _ = c.setenv("PULSE_SERVER", &env.pulse, 1);
                _ = c.setenv("LIBGL_ALWAYS_SOFTWARE", "1", 1);
                _ = c.setenv("SKETERM_WEB_OZONE", "wayland", 1);
                _ = c.setenv("SKETERM_WEB_GPU", "0", 1);
                _ = c.unsetenv("WAYLAND_SOCKET");
                _ = c.unsetenv("DISPLAY");
                _ = c.unsetenv("XAUTHORITY");
            }
            var argv: [6:null]?[*:0]const u8 = .{ bin, "--socket", sock_z, "--cache-dir", cache_z, null };
            _ = c.execv(bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        if (pid < 0) return self.failStart("could not start the browser helper (fork failed)");
        self.pid = pid;

        // Connect loop, watching for a helper that dies on startup
        // (missing libcef, bad CEF deployment) — that never binds.
        const deadline = clock.nowMs() + SPAWN_WAIT_MS;
        const fd: c_int = while (true) {
            var status: c_int = 0;
            if (c.waitpid(self.pid, &status, c.WNOHANG) == self.pid) {
                self.pid = -1;
                return self.failStart("the browser helper exited during startup (see its stderr; usually a broken CEF install)");
            }
            if (self.tryConnect(sock)) |fd| break fd;
            if (clock.nowMs() >= deadline) {
                self.killChild();
                return self.failStart("the browser helper did not bind its socket in time");
            }
            _ = c.usleep(100_000);
        };
        self.fd = fd;
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        self.state = .ready;

        self.send(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = self.client_name }) catch {
            self.lost();
            self.reason = "the browser helper closed the connection during the handshake";
            return false;
        };
        // Wait for the ack so protocol and capability skew surface here
        // rather than as a silent later timeout.
        const ack_deadline = clock.nowMs() + 10_000;
        while (self.state == .ready and !self.cap_semantic and !self.cap_shm) {
            if (clock.nowMs() >= ack_deadline) {
                self.killChild();
                self.lost();
                self.reason = "the browser helper never answered the protocol handshake";
                return false;
            }
            self.pumpOnce(50);
        }
        if (self.state == .ready) {
            self.helper_gen +%= 1;
            if (self.helper_gen == 0) self.helper_gen = 1;
            self.writePresence();
        }
        return self.state == .ready;
    }

    fn failStart(self: *Engine, reason: []const u8) bool {
        self.state = .unavailable;
        self.reason = reason;
        self.retryable = true;
        return false;
    }

    fn killChild(self: *Engine) void {
        if (self.pid <= 0) return;
        _ = c.kill(self.pid, c.SIGKILL);
        var status: c_int = 0;
        _ = c.waitpid(self.pid, &status, 0);
        self.pid = -1;
    }

    fn tryConnect(self: *Engine, path: [:0]const u8) ?c_int {
        _ = self;
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        if (path.len + 1 > addr.sun_path.len) return null;
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..path.len], path);
        const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return null;
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
            _ = c.close(fd);
            return null;
        }
        return fd;
    }

    // ---- views ------------------------------------------------------

    pub fn findView(self: *Engine, id: u32) ?*View {
        for (self.views.items) |v| {
            if (v.id == id) return v;
        }
        return null;
    }

    /// Make `id` what a handle-less call resolves to. Called whenever a
    /// tool addresses a view, so "current" tracks what the caller is
    /// actually working on rather than what it opened first.
    pub fn setCurrent(self: *Engine, id: u32) void {
        if (self.findView(id) != null) self.current = id;
    }

    /// Create a headless view; `url` may be empty for a blank page.
    ///
    /// With a url and a helper advertising `view-create-url` the browser
    /// is created AT it, so the view holds exactly one document. The
    /// create-then-navigate fallback (older helper) mints about:blank
    /// first, which is what `load_seq` lets a settle see past.
    pub fn openView(self: *Engine, url: []const u8, w: u16, h: u16) !*View {
        return self.openViewIn(url, w, h, .default, null);
    }

    /// As `openView`, in a chosen identity, optionally POLICIED.
    ///
    /// FAIL CLOSED: every profile and policy check runs BEFORE a view is
    /// minted or a single frame is written, so a refusal leaves nothing
    /// behind and — crucially — never loads the requested page into the
    /// shared jar, and never loads it UNPOLICED.
    pub fn openViewIn(self: *Engine, url: []const u8, w: u16, h: u16, spec: ProfileSpec, policy_arg: ?*const NetPolicy) !*View {
        if (!self.ensure()) return error.Unavailable;

        // The effective policy: the explicit one, else the profile's
        // session default when the open names a profile.
        var policy: ?*const NetPolicy = policy_arg;
        if (policy == null and spec == .named) {
            if (self.profile_policy.getPtr(spec.named)) |p| policy = p;
        }
        if (policy != null) {
            if (!self.cap_net_policy) return error.PolicyUnsupported;
            // The helper can hold this many policies; past it a policied
            // view would silently run unpoliced, so refuse instead.
            if (self.views.items.len >= proto.MAX_POLICY_VIEWS) return error.PolicyTooManyViews;
        }

        var ctx_id: u32 = 0;
        var ctx_ephemeral = false;
        var profile_name: []const u8 = "";
        if (spec != .default) {
            // Both caps, or nothing: with CAP_CONTEXTS alone an old
            // helper resolves an unknown context through the SHARED jar
            // and never says so.
            if (!self.cap_contexts or !self.cap_contexts_fail_closed) return error.ContextsUnsupported;
            if (spec == .named) profile_name = spec.named;
            const pick = try self.resolveContext(spec);
            ctx_id = pick.id;
            ctx_ephemeral = pick.ephemeral;
        }
        errdefer self.releaseContext(ctx_id);

        // Own the policy copy BEFORE any frame is sent, so an OOM here
        // cannot leave the helper holding a policy for a view that
        // never arrives.
        var owned_pol: ?NetPolicy = if (policy) |p| try dupePolicy(self.gpa, p.*) else null;
        errdefer if (owned_pol) |*p| freePolicy(self.gpa, p);
        var pol_serial: u32 = 0;
        if (policy) |p| {
            pol_serial = self.next_policy_serial;
            self.next_policy_serial += 1;
            self.send(policyFrame(self.next_view, pol_serial, p)) catch return error.Unavailable;
            if (p.block_ads) |on| {
                self.send(proto.InterceptSet{ .view = self.next_view, .enabled = if (on) 1 else 0 }) catch return error.Unavailable;
            }
        }

        const v = try self.gpa.create(View);
        // Covers both halves: before the append it just destroys the
        // view, after it also unlinks it from `views` (a bare destroy
        // there would leave a dangling pointer in the list).
        errdefer self.abandonView(v);
        const owned_profile: ?[]u8 = if (profile_name.len > 0) try self.gpa.dupe(u8, profile_name) else null;
        v.* = .{
            .id = self.next_view,
            .w = w,
            .h = h,
            .context = ctx_id,
            .profile = owned_profile,
            .ephemeral_ctx = ctx_ephemeral,
            .pol = owned_pol,
            .pol_serial = pol_serial,
            .pol_active = policy != null,
        };
        // Ownership moved into the view; the errdefer above must not
        // double-free through the local.
        owned_pol = null;
        self.next_view += 1;
        try self.views.append(self.gpa, v);
        if (url.len > 0 and self.cap_view_url) {
            self.send(proto.ViewCreateUrl{
                .view = v.id,
                .w = w,
                .h = h,
                .scale_x1000 = 1000,
                .context = ctx_id,
                .url = url,
            }) catch return error.Unavailable;
        } else {
            self.send(proto.ViewCreate{
                .view = v.id,
                .w = w,
                .h = h,
                .scale_x1000 = 1000,
                .context = ctx_id,
            }) catch return error.Unavailable;
        }
        // A hidden view is never painted; headless views are always
        // "shown" — nothing else would ever show them.
        self.send(proto.ViewShow{ .view = v.id }) catch return error.Unavailable;
        if (url.len > 0 and !self.cap_view_url) {
            self.send(proto.Navigate{ .view = v.id, .url = url }) catch return error.Unavailable;
        }
        self.current = v.id;
        return v;
    }

    /// Drop a half-built view, whether or not it reached `views`.
    fn abandonView(self: *Engine, v: *View) void {
        for (self.views.items, 0..) |item, i| {
            if (item != v) continue;
            _ = self.views.orderedRemove(i);
            break;
        }
        v.deinit(self.gpa);
        self.gpa.destroy(v);
    }

    const CtxPick = struct { id: u32, ephemeral: bool };

    /// The context id a view must be created with, publishing it to the
    /// helper first when needed. Frame ORDER on the one stream is what
    /// guarantees the helper handles `context_create` before the
    /// `view_create` naming it — there is no ack to wait for.
    fn resolveContext(self: *Engine, spec: ProfileSpec) ProfileError!CtxPick {
        switch (spec) {
            .default => return .{ .id = 0, .ephemeral = false },
            .ephemeral => {
                const id = self.next_eph;
                self.send(proto.ContextCreate{
                    .id = id,
                    .ephemeral = 1,
                    .name = "",
                    .proxy = "",
                }) catch return error.StoreIo;
                self.live.append(self.gpa, .{
                    .id = id,
                    .name = &.{},
                    .ephemeral = true,
                    .published_gen = self.helper_gen,
                    .views = 1,
                }) catch return error.StoreIo;
                self.next_eph += 1;
                return .{ .id = id, .ephemeral = true };
            },
            .named => |name| {
                if (!webprofiles.validName(name)) return error.InvalidName;
                const store = if (self.store) |*s| s else return error.StoreUnavailable;
                const id = store.ensure(name) catch |err| return switch (err) {
                    error.BadName => error.InvalidName,
                    error.Io, error.OutOfMemory => error.StoreIo,
                };
                var key_buf: [webprofiles.MAX_NAME + webprofiles.JAR_PREFIX.len]u8 = undefined;
                const key = webprofiles.Store.jarKey(&key_buf, name);
                for (self.live.items) |*ctx| {
                    if (ctx.ephemeral or !std.mem.eql(u8, ctx.name, name)) continue;
                    if (ctx.published_gen != self.helper_gen) {
                        self.send(publishFrame(ctx.id, key)) catch return error.StoreIo;
                        ctx.published_gen = self.helper_gen;
                    }
                    ctx.views += 1;
                    store.touch(name, clock.nowMs());
                    return .{ .id = ctx.id, .ephemeral = false };
                }
                const owned = self.gpa.dupe(u8, name) catch return error.StoreIo;
                errdefer self.gpa.free(owned);
                self.send(publishFrame(id, key)) catch return error.StoreIo;
                self.live.append(self.gpa, .{
                    .id = id,
                    .name = owned,
                    .ephemeral = false,
                    .published_gen = self.helper_gen,
                    .views = 1,
                }) catch return error.StoreIo;
                store.touch(name, clock.nowMs());
                return .{ .id = id, .ephemeral = false };
            },
        }
    }

    fn policyFrame(view_id: u32, serial: u32, p: *const NetPolicy) proto.NetPolicySet {
        return .{
            .view = view_id,
            .serial = serial,
            .flags = if (p.allow_private) proto.NetPolicySet.flag_allow_private else 0,
            .block_types = p.block_types,
            .allow_schemes = p.allow_schemes,
            .max_requests = p.max_requests,
            .max_bytes = p.max_bytes,
            .max_navigations = p.max_navigations,
            .deadline_ms = p.deadline_ms,
            .allow_top = p.allow_top,
            .allow_sub = p.allow_sub,
        };
    }

    /// The name is the JAR KEY the helper builds its cache path from —
    /// never a display string (there is none here), which is why it
    /// carries `webprofiles.JAR_PREFIX`.
    fn publishFrame(id: u32, key: []const u8) proto.ContextCreate {
        return .{ .id = id, .ephemeral = 0, .name = key, .proxy = "" };
    }

    /// One fewer view in `id`. A persistent context is KEPT published
    /// (a later web_open on the same profile must not pay a re-create);
    /// an ephemeral one dies with its last view, jar and all.
    fn releaseContext(self: *Engine, id: u32) void {
        if (id == 0) return;
        for (self.live.items, 0..) |*ctx, i| {
            if (ctx.id != id) continue;
            if (ctx.views > 0) ctx.views -= 1;
            if (ctx.views == 0 and ctx.ephemeral) {
                if (self.state == .ready) self.send(proto.ContextDestroy{ .id = id }) catch {};
                const dead = self.live.orderedRemove(i);
                if (dead.name.len > 0) self.gpa.free(dead.name);
            }
            return;
        }
    }

    pub fn closeView(self: *Engine, id: u32) void {
        for (self.views.items, 0..) |v, i| {
            if (v.id != id) continue;
            if (self.state == .ready) self.send(proto.ViewDestroy{ .view = id }) catch {};
            const context = v.context;
            v.deinit(self.gpa);
            self.gpa.destroy(v);
            _ = self.views.orderedRemove(i);
            self.releaseContext(context);
            if (self.current == id)
                self.current = if (self.views.items.len > 0) self.views.items[self.views.items.len - 1].id else 0;
            return;
        }
    }

    // ---- profiles ----------------------------------------------------

    /// One profile as the tools report it.
    pub const ProfileInfo = struct {
        name: []const u8,
        id: u32,
        views: u32,
        created_ms: i64,
        last_used_ms: i64,
        /// Published to the browser helper that is running right now.
        live: bool,
    };

    /// Whether this helper CAN serve profiles. Only meaningful once the
    /// handshake happened: before that the caps are simply unknown.
    pub fn contextsSupported(self: *const Engine) bool {
        return self.cap_contexts and self.cap_contexts_fail_closed;
    }

    /// Can a profile be opened at all? Deliberately does NOT spawn the
    /// helper (the same rule listing follows): with no helper yet, the
    /// store alone decides, and `openViewIn` still fails closed if the
    /// helper turns out to lack the caps.
    pub fn profilesAvailable(self: *Engine) bool {
        self.openStore();
        if (self.store == null) return false;
        if (self.state == .ready) return self.contextsSupported();
        return true;
    }

    /// The sentence explaining a false `profilesAvailable`.
    pub fn profileUnavailableReason(self: *Engine) []const u8 {
        self.openStore();
        if (self.store == null)
            return if (self.store_reason.len > 0) self.store_reason else "the browser profile store is unavailable";
        if (self.state == .ready and !self.contextsSupported())
            return "this browser helper does not advertise isolated identity contexts (capabilities 'contexts' + 'contexts-fail-closed'); named profiles are refused rather than silently sharing the default cookie jar";
        return "";
    }

    /// Where the profiles' cookies and caches live; null when there is
    /// no store.
    pub fn profileStorePath(self: *Engine) ?[]const u8 {
        self.openStore();
        if (self.store) |*s| return s.root;
        return null;
    }

    /// Every known profile, store ∪ live. Never spawns the helper.
    pub fn profileList(self: *Engine, arena: std.mem.Allocator) ![]ProfileInfo {
        self.openStore();
        var out: std.ArrayList(ProfileInfo) = .empty;
        const store = if (self.store) |*s| s else return out.items;
        for (store.list()) |e| {
            var views: u32 = 0;
            var live = false;
            for (self.live.items) |ctx| {
                if (ctx.ephemeral or !std.mem.eql(u8, ctx.name, e.name)) continue;
                views = ctx.views;
                live = ctx.published_gen == self.helper_gen and self.state == .ready;
            }
            try out.append(arena, .{
                .name = try arena.dupe(u8, e.name),
                .id = e.id,
                .views = views,
                .created_ms = e.created_ms,
                .last_used_ms = e.last_used_ms,
                .live = live,
            });
        }
        return out.items;
    }

    /// How many open views are using `name` right now.
    pub fn profileViewCount(self: *const Engine, name: []const u8) u32 {
        var n: u32 = 0;
        for (self.views.items) |v| {
            const p = v.profile orelse continue;
            if (std.mem.eql(u8, p, name)) n += 1;
        }
        return n;
    }

    /// Erase a profile's storage and RETIRE its id, so the next use
    /// starts from a freshly allocated jar directory — a partially
    /// failed removal can then never resurface as this profile's
    /// cookies.
    /// @return the context id that was retired.
    pub fn resetProfile(self: *Engine, name: []const u8) ProfileError!u32 {
        if (!webprofiles.validName(name)) return error.InvalidName;
        self.openStore();
        const store = if (self.store) |*s| s else return error.StoreUnavailable;
        if (self.profileViewCount(name) > 0) return error.InUse;
        const entry = store.find(name) orelse return error.NoProfile;
        for (self.live.items, 0..) |ctx, i| {
            if (ctx.ephemeral or !std.mem.eql(u8, ctx.name, name)) continue;
            if (self.state == .ready) self.send(proto.ContextDestroy{ .id = ctx.id }) catch {};
            const dead = self.live.orderedRemove(i);
            if (dead.name.len > 0) self.gpa.free(dead.name);
            break;
        }
        _ = store.retire(name) catch |err| return switch (err) {
            error.BadName => error.InvalidName,
            error.Io, error.OutOfMemory => error.StoreIo,
        };
        return entry.id;
    }

    // ---- enforced network policy ------------------------------------

    /// Register (replace) the session-default policy for a profile
    /// name. In-memory only, BY DESIGN: persisting it would let the
    /// store's corrupt-rebuild path silently loosen a profile.
    pub fn setProfilePolicy(self: *Engine, name: []const u8, p: *const NetPolicy) !void {
        const owned = try dupePolicy(self.gpa, p.*);
        errdefer {
            var tmp = owned;
            freePolicy(self.gpa, &tmp);
        }
        const gop = try self.profile_policy.getOrPut(self.gpa, name);
        if (gop.found_existing) {
            freePolicy(self.gpa, gop.value_ptr);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
        }
        gop.value_ptr.* = owned;
    }

    pub fn profilePolicy(self: *Engine, name: []const u8) ?*const NetPolicy {
        return self.profile_policy.getPtr(name);
    }

    /// Which fields a tighten request actually moved, and which were
    /// silently-dangerous loosenings it REFUSED to apply (the caller
    /// reports both; an SDK must never mistake "ignored" for
    /// "applied").
    pub const TightenReport = struct {
        tightened: [10][]const u8 = undefined,
        n_tightened: usize = 0,
        ignored: [10][]const u8 = undefined,
        n_ignored: usize = 0,

        fn tight(self: *TightenReport, name: []const u8) void {
            self.tightened[self.n_tightened] = name;
            self.n_tightened += 1;
        }

        fn ign(self: *TightenReport, name: []const u8) void {
            self.ignored[self.n_ignored] = name;
            self.n_ignored += 1;
        }
    };

    /// TIGHTEN-ONLY policy update for a live view: host sets can only
    /// shrink, budgets only lower, type blocks only grow, allow_private
    /// only turn off. Monotone, so "did the old policy still apply to
    /// the requests in flight" is never a question a caller has to ask.
    /// A field the patch does not carry is left exactly as it was.
    pub fn tightenViewPolicy(self: *Engine, view_id: u32, incoming: *const NetPolicyPatch) !TightenReport {
        const v = self.findView(view_id) orelse return error.NoView;
        const old = if (v.pol) |*p| p else return error.NoPolicy;
        var report = TightenReport{};
        var next = try dupePolicy(self.gpa, old.*);
        errdefer freePolicy(self.gpa, &next);

        if (incoming.allow_top.len > 0) {
            var extra = false;
            for (incoming.allow_top) |h| {
                if (!hostListed(old.allow_top, h)) extra = true;
            }
            if (extra) report.ign("allow_hosts");
            const kept = try intersectHosts(self.gpa, old.allow_top, incoming.allow_top);
            if (kept.len < old.allow_top.len) {
                freeHostList(self.gpa, next.allow_top);
                next.allow_top = kept;
                report.tight("allow_hosts");
            } else {
                freeHostList(self.gpa, kept);
            }
        }
        if (incoming.allow_sub.len > 0) {
            var extra = false;
            for (incoming.allow_sub) |h| {
                if (!hostListed(old.allow_sub, h)) extra = true;
            }
            if (extra) report.ign("allow_subresource_hosts");
            const kept = try intersectHosts(self.gpa, old.allow_sub, incoming.allow_sub);
            if (kept.len < old.allow_sub.len) {
                freeHostList(self.gpa, next.allow_sub);
                next.allow_sub = kept;
                report.tight("allow_subresource_hosts");
            } else {
                freeHostList(self.gpa, kept);
            }
        }
        if (incoming.block_types & ~old.block_types != 0) {
            next.block_types = old.block_types | incoming.block_types;
            report.tight("block_types");
        }
        if (incoming.allow_schemes) |want| {
            const narrowed = old.allow_schemes & want;
            if (narrowed != old.allow_schemes) {
                next.allow_schemes = narrowed;
                report.tight("allow_schemes");
            }
            if (want & ~old.allow_schemes != 0) report.ign("allow_schemes");
        }
        if (incoming.allow_private) |want| {
            if (old.allow_private and !want) {
                next.allow_private = false;
                report.tight("allow_private_addresses");
            } else if (!old.allow_private and want) {
                report.ign("allow_private_addresses");
            }
        }
        tightenBudget(u32, old.max_requests, incoming.max_requests, &next.max_requests, &report, "max_requests");
        tightenBudget(u64, old.max_bytes, incoming.max_bytes, &next.max_bytes, &report, "max_bytes");
        tightenBudget(u32, old.max_navigations, incoming.max_navigations, &next.max_navigations, &report, "max_navigations");
        tightenBudget(u32, old.deadline_ms, incoming.deadline_ms, &next.deadline_ms, &report, "deadline_ms");
        if (incoming.block_ads) |on| {
            if (on) {
                next.block_ads = true;
                report.tight("block_ads");
                if (self.state == .ready) self.send(proto.InterceptSet{ .view = view_id, .enabled = 1 }) catch {};
            } else {
                report.ign("block_ads");
            }
        }

        if (report.n_tightened == 0) {
            freePolicy(self.gpa, &next);
            return report;
        }
        const serial = self.next_policy_serial;
        self.next_policy_serial += 1;
        self.send(policyFrame(view_id, serial, &next)) catch {
            freePolicy(self.gpa, &next);
            return error.Unavailable;
        };
        freePolicy(self.gpa, &v.pol.?);
        v.pol = next;
        v.pol_serial = serial;
        return report;
    }

    /// An omitted budget is untouched; an explicit 0 asks for "unbounded",
    /// which on a bounded view is a loosening and is named as such.
    fn tightenBudget(comptime T: type, old: T, incoming: ?T, out: *T, report: *TightenReport, name: []const u8) void {
        const want = incoming orelse return;
        if (want != 0 and (old == 0 or want < old)) {
            out.* = want;
            report.tight(name);
        } else if (want == 0 or want > old) {
            if (old != 0 or want != 0) report.ign(name);
        }
    }

    fn hostListed(hosts: []const []const u8, host: []const u8) bool {
        for (hosts) |h| {
            if (std.mem.eql(u8, h, host)) return true;
        }
        return false;
    }

    /// Owned list of `old` entries that also appear in `incoming`.
    fn intersectHosts(gpa: std.mem.Allocator, old: []const []const u8, incoming: []const []const u8) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |h| gpa.free(h);
            out.deinit(gpa);
        }
        for (old) |h| {
            if (hostListed(incoming, h)) try out.append(gpa, try gpa.dupe(u8, h));
        }
        return try out.toOwnedSlice(gpa);
    }

    /// Freshen a view's policy accounting (one req + bounded pump).
    pub fn netPolicyStatus(self: *Engine, id: u32, budget_ms: i64) !*View {
        if (!self.ensure()) return error.Unavailable;
        if (self.findView(id) == null) return error.NoView;
        if (self.cap_net_policy) {
            self.send(proto.NetPolicyReq{ .view = id }) catch return error.Unavailable;
            const deadline = clock.nowMs() + @max(budget_ms, 100);
            while (clock.nowMs() < deadline) {
                if (self.state != .ready) return error.Unavailable;
                self.pumpOnce(40);
                break;
            }
        }
        return self.findView(id) orelse error.NoView;
    }

    pub fn navigate(self: *Engine, id: u32, url: []const u8) !void {
        if (!self.ensure()) return error.Unavailable;
        if (self.findView(id) == null) return error.NoView;
        self.send(proto.Navigate{ .view = id, .url = url }) catch return error.Unavailable;
    }

    pub fn navAction(self: *Engine, id: u32, action: proto.NavAct) !void {
        if (!self.ensure()) return error.Unavailable;
        const v = self.findView(id) orelse return error.NoView;
        self.send(proto.NavAction{ .view = id, .action = @intFromEnum(action) }) catch return error.Unavailable;
        if (action == .stop) v.reader_guards.invalidate();
    }

    /// Wheel scroll through the ordinary input path, at the view
    /// centre (headless has no remembered pointer position).
    pub fn scroll(self: *Engine, id: u32, dx: i32, dy: i32) !void {
        if (!self.ensure()) return error.Unavailable;
        const v = self.findView(id) orelse return error.NoView;
        self.awaitFirstPaint(id, 5_000);
        self.send(proto.InputScroll{
            .view = id,
            .x = @intCast(v.w / 2),
            .y = @intCast(v.h / 2),
            .dx = dx,
            .dy = dy,
            .mods = 0,
        }) catch return error.Unavailable;
    }

    /// The full text of the last eval result on `id`, if any.
    pub fn lastEval(self: *Engine, id: u32) ?[]const u8 {
        const v = self.findView(id) orelse return null;
        return v.last_eval;
    }

    // ---- request interception ---------------------------------------

    /// Enable/disable blocking; `id` 0 is the process-wide default.
    pub fn setNetwork(self: *Engine, id: u32, enabled: bool) !void {
        if (!self.ensure()) return error.Unavailable;
        self.send(proto.InterceptSet{ .view = id, .enabled = if (enabled) 1 else 0 }) catch return error.Unavailable;
    }

    /// Reload the filter set (seed + config dir + `paths`).
    pub fn reloadLists(self: *Engine, paths: []const []const u8) !void {
        if (!self.ensure()) return error.Unavailable;
        self.send(proto.InterceptLists{ .paths = paths }) catch return error.Unavailable;
    }

    /// Current per-view counters (freshened by a status_req + pump).
    pub fn networkStatus(self: *Engine, id: u32, budget_ms: i64) !struct {
        enabled: bool,
        blocked: u32,
        total: u32,
        rules: u32,
    } {
        if (!self.ensure()) return error.Unavailable;
        if (self.findView(id) == null) return error.NoView;
        self.send(proto.InterceptStatusReq{ .view = id }) catch return error.Unavailable;
        const deadline = clock.nowMs() + @max(budget_ms, 100);
        // One short settle so a just-updated count lands; the counters
        // are pushed unsolicited too, so this rarely waits.
        while (clock.nowMs() < deadline) {
            if (self.state != .ready) return error.Unavailable;
            self.pumpOnce(40);
            break;
        }
        const current = self.findView(id) orelse return error.NoView;
        return .{ .enabled = current.net_enabled, .blocked = current.net_blocked, .total = current.net_total, .rules = current.net_rules };
    }

    /// Pull recent log entries as one JSON object; caller's arena owns
    /// the returned copy.
    pub fn networkLog(self: *Engine, arena: std.mem.Allocator, id: u32, since: u32, max: u16, budget_ms: i64) ![]const u8 {
        if (!self.ensure()) return error.Unavailable;
        if (!self.cap_intercept) return error.NoIntercept;
        const v = self.findView(id) orelse return error.NoView;
        if (v.net_log) |old| {
            self.gpa.free(old);
            v.net_log = null;
        }
        v.net_log_waiting = true;
        // The reason-carrying lane when the helper has it; the legacy
        // frame otherwise. Both park the same JSON shape on the view.
        if (self.cap_net_policy) {
            self.send(proto.NetLogReq{ .view = id, .since = since, .max = max }) catch return error.Unavailable;
        } else {
            self.send(proto.InterceptLogReq{ .view = id, .since = since, .max = max }) catch return error.Unavailable;
        }
        const deadline = clock.nowMs() + @max(budget_ms, 100);
        while (clock.nowMs() < deadline) {
            if (self.findView(id)) |vv| {
                if (vv.net_log) |json| {
                    vv.net_log_waiting = false;
                    return arena.dupe(u8, json);
                }
            } else return error.NoView;
            if (self.state != .ready) return error.Unavailable;
            self.pumpOnce(40);
        }
        return error.Timeout;
    }

    // ---- semantic round trips ---------------------------------------

    /// Wait, bounded, for the view's FIRST composited frame.
    ///
    /// The engine has nothing to hit-test until it has composited once,
    /// and input aimed at a view in that state is swallowed silently
    /// (smoke-web stage 6 retries its clicks for the same reason). It
    /// used to be hidden by the wasted about:blank document: the page
    /// had painted long before anything acted on it. Cheap after the
    /// first frame — `frame_gen` never returns to 0.
    fn awaitFirstPaint(self: *Engine, view_id: u32, budget_ms: i64) void {
        const v0 = self.findView(view_id) orelse return;
        if (v0.frame_gen != 0) return;
        self.send(proto.FrameRequest{ .view = view_id, .flags = 0 }) catch return;
        const deadline = clock.nowMs() + budget_ms;
        while (clock.nowMs() < deadline) {
            const v = self.findView(view_id) orelse return;
            if (v.frame_gen != 0) return;
            if (self.state != .ready) return;
            self.pumpOnce(20);
        }
    }

    /// Run one semantic operation to completion under `budget_ms`.
    /// Synchronous by design: this driver is called from the MCP
    /// single-threaded dispatch, so nothing else could overlap it.
    pub fn runOp(self: *Engine, arena: std.mem.Allocator, view_id: u32, req: OpReq, budget_ms: i64) !OpOut {
        if (!self.ensure()) return error.Unavailable;
        if (!self.cap_semantic) return error.NoSemantic;
        if (self.findView(view_id) == null) return error.NoView;

        // `click`/`hover` are synthesized through the real input path,
        // which needs a composited frame to hit-test against.
        if (req.kind == .act) self.awaitFirstPaint(view_id, @min(budget_ms, 5_000));

        const ki = @intFromEnum(req.kind);
        const v = self.findView(view_id) orelse return error.NoView;
        if (!self.cap_semantic_request_ids and v.legacy_quarantine.isHeld(ki))
            return error.LegacySemanticReplyPending;
        // Drop a stale parked reply from an earlier timed-out call of
        // the same kind: it answers an older question.
        if (v.inbox[ki]) |old| {
            self.gpa.free(old.text);
            v.inbox[ki] = null;
        }
        const request = if (self.cap_semantic_request_ids) self.nextSemanticRequest() else 0;
        v.waiting[ki] = true;
        v.waiting_request[ki] = request;
        if (req.kind == .snapshot)
            v.want_full = req.mode == @intFromEnum(proto.SnapMode.full) or req.scope != 0;
        var timed_out = false;
        defer self.finishWait(view_id, ki, request, timed_out);

        const sent: anyerror!void = switch (req.kind) {
            .snapshot => self.sendSemantic(request, proto.SemSnapshotReq{ .view = view_id, .mode = req.mode, .detail = req.detail, .scope = req.scope }),
            .act => if (if (self.cap_reader_ids) readerGuard(v, req.id) else null) |guard|
                self.sendSemantic(request, proto.SemActGuarded{
                    .view = view_id,
                    .doc_gen = guard.doc_gen,
                    .rev = guard.rev,
                    .id = req.id,
                    .guard = guard.guard,
                    .action = req.action,
                    .arg = req.arg,
                })
            else
                self.sendSemantic(request, proto.SemAction{ .view = view_id, .id = req.id, .action = req.action, .arg = req.arg }),
            .expand => self.sendSemantic(request, proto.SemExpand{ .view = view_id, .id = req.id, .off = req.off, .len = req.len }),
            .query => self.sendSemantic(request, proto.SemQueryReq{ .view = view_id, .kind = req.action, .arg = req.arg }),
            .read => if (self.cap_reader_ids)
                self.sendSemantic(request, proto.SemReadIds{ .view = view_id })
            else
                self.sendSemantic(request, proto.SemRead{ .view = view_id }),
            .eval => self.sendSemantic(request, proto.SemEval{ .view = view_id, .flags = req.flags, .timeout_ms = req.timeout_ms, .code = .{ .s = req.arg } }),
        };
        sent catch return error.Unavailable;

        const deadline = clock.nowMs() + @max(budget_ms, 100);
        while (true) {
            if (self.findView(view_id)) |vv| {
                if (vv.inbox[ki]) |sem| {
                    vv.inbox[ki] = null;
                    defer self.gpa.free(sem.text);
                    return .{
                        .ok = sem.ok,
                        .text = try arena.dupe(u8, sem.text),
                        .doc_gen = sem.doc_gen,
                        .rev = sem.rev,
                        .snap_kind = sem.snap_kind,
                    };
                }
            } else return error.NoView;
            if (self.state != .ready) return error.Unavailable;
            if (clock.nowMs() >= deadline) {
                timed_out = true;
                return .{ .timed_out = true };
            }
            self.pumpOnce(40);
        }
    }

    fn readerGuard(v: *const View, id: u32) ?reader_guards.Entry {
        return v.reader_guards.get(id);
    }

    fn nextSemanticRequest(self: *Engine) u32 {
        const request = self.next_sem_request;
        self.next_sem_request +%= 1;
        if (self.next_sem_request == 0) self.next_sem_request = 1;
        return request;
    }

    fn finishWait(self: *Engine, view_id: u32, ki: usize, request: u32, timed_out: bool) void {
        const v = self.findView(view_id) orelse return;
        if (!v.waiting[ki] or v.waiting_request[ki] != request) return;
        v.waiting[ki] = false;
        v.waiting_request[ki] = 0;
        if (timed_out and request == 0) v.legacy_quarantine.mark(ki);
    }

    // ---- frames / screenshot ----------------------------------------

    /// PNG of the view's newest software frame. Briefly nudges the
    /// engine for a fresh paint, but settles for the existing buffer —
    /// a static page repaints nothing, which is correct, not stale.
    pub fn screenshotPng(self: *Engine, arena: std.mem.Allocator, view_id: u32, budget_ms: i64) ![]u8 {
        if (!self.ensure()) return error.Unavailable;
        const v0 = self.findView(view_id) orelse return error.NoView;
        const gen0 = v0.frame_gen;
        const had_frame = v0.buf_fd >= 0;
        self.send(proto.FrameRequest{ .view = view_id, .flags = 0 }) catch return error.Unavailable;
        const deadline = clock.nowMs() + @max(budget_ms, 200);
        while (clock.nowMs() < deadline) {
            const v = self.findView(view_id) orelse return error.NoView;
            if (v.frame_gen > gen0 and v.buf_fd >= 0) break;
            // With a frame already in hand, only a short grace for a
            // fresher paint; without one, wait the whole budget.
            if (had_frame and clock.nowMs() >= deadline - @max(budget_ms - 500, 0)) break;
            self.pumpOnce(40);
        }
        const v = self.findView(view_id) orelse return error.NoView;
        if (v.buf_fd < 0) return error.NoFrame;
        // A stride below `w * 4` would make the row walk in `shmToRgba`
        // read past the mapping; `proto.frameSize` is the one place that
        // rule lives (see its docblock).
        const size: usize = proto.frameSize(v.buf_w, v.buf_h, v.buf_stride) orelse return error.NoFrame;
        const mapped = c.mmap(null, size, c.PROT_READ, c.MAP_SHARED, v.buf_fd, 0);
        if (mapped == c.MAP_FAILED) return error.NoFrame;
        const pixels: [*]const u8 = @ptrCast(mapped.?);
        defer _ = c.munmap(mapped, size);
        // CEF software frames are BGRA with an opaque page background;
        // xrgb forces alpha to 255 so a PNG viewer never composites it.
        const rgba = try png.shmToRgba(arena, pixels[0..size], v.buf_w, v.buf_h, v.buf_stride, @intFromEnum(png.ShmFormat.xrgb8888));
        return png.encodeRgba(arena, rgba, v.buf_w, v.buf_h);
    }

    // ---- socket plumbing --------------------------------------------

    /// Bounded blocking-equivalent write on the non-blocking fd.
    fn send(self: *Engine, value: anytype) !void {
        if (self.state != .ready or self.fd < 0) return error.NotReady;
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        try proto.encode(self.gpa, &buf, value);
        const deadline = clock.nowMs() + SEND_TIMEOUT_MS;
        var off: usize = 0;
        while (off < buf.items.len) {
            const n = c.write(self.fd, buf.items.ptr + off, buf.items.len - off);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            if (n < 0) {
                const e = std.c._errno().*;
                if (e == c.EINTR) continue;
                if (e != c.EAGAIN and e != c.EWOULDBLOCK) {
                    self.lost();
                    return error.NotReady;
                }
            }
            if (clock.nowMs() >= deadline) {
                self.lost();
                self.reason = "the browser helper stopped draining its socket";
                return error.NotReady;
            }
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLOUT, .revents = 0 };
            _ = c.poll(&pfd, 1, 50);
        }
    }

    fn sendSemantic(self: *Engine, request: u32, value: anytype) !void {
        if (request == 0) return self.send(value);
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.gpa);
        const wrapped = try proto.semRequestWrap(self.gpa, &payload, request, value);
        return self.send(wrapped);
    }

    /// Wait up to `slice_ms` for helper bytes and dispatch what
    /// arrived. Callers loop this under their own deadline.
    pub fn pumpOnce(self: *Engine, slice_ms: i32) void {
        if (self.fd < 0) return;
        var pfd = c.struct_pollfd{ .fd = self.fd, .events = c.POLLIN, .revents = 0 };
        const r = c.poll(&pfd, 1, slice_ms);
        if (r < 0) return;
        if (r == 0) return;
        if (pfd.revents & (c.POLLHUP | c.POLLERR) != 0 and pfd.revents & c.POLLIN == 0) {
            self.lost();
            return;
        }
        _ = self.readAvailable();
    }

    /// Drain the socket without blocking and dispatch complete frames.
    /// False = the connection is gone (state already updated).
    fn readAvailable(self: *Engine) bool {
        if (self.fd < 0) return false;
        var buf: [64 * 1024]u8 = undefined;
        // Byte budget per call so a flooding peer cannot starve the
        // caller-side deadline (the appdrive fillAvailable rule).
        var budget: usize = 4 * 1024 * 1024;
        while (budget > 0) {
            var iov = c.struct_iovec{ .iov_base = &buf, .iov_len = buf.len };
            var cbuf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([64]u8);
            var mh = std.mem.zeroes(c.struct_msghdr);
            mh.msg_iov = @ptrCast(&iov);
            mh.msg_iovlen = 1;
            mh.msg_control = &cbuf;
            mh.msg_controllen = cbuf.len;
            const n = c.recvmsg(self.fd, &mh, 0);
            if (n == 0) {
                self.lost();
                return false;
            }
            if (n < 0) {
                const e = std.c._errno().*;
                if (e == c.EAGAIN or e == c.EWOULDBLOCK) break;
                if (e == c.EINTR) continue;
                self.lost();
                return false;
            }
            const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
            if (@as(usize, @intCast(mh.msg_controllen)) >= hdr_size) {
                const hdr: *const c.struct_cmsghdr = @ptrCast(@alignCast(&cbuf));
                if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS and
                    @as(usize, @intCast(hdr.cmsg_len)) >= hdr_size + @sizeOf(c_int))
                {
                    // One control message can carry several descriptors;
                    // reading only the first would leak the rest.
                    const bytes = @as(usize, @intCast(hdr.cmsg_len)) - hdr_size;
                    var off: usize = 0;
                    while (off + @sizeOf(c_int) <= bytes and hdr_size + off + @sizeOf(c_int) <= cbuf.len) : (off += @sizeOf(c_int)) {
                        var passed: c_int = undefined;
                        @memcpy(std.mem.asBytes(&passed), cbuf[hdr_size + off ..][0..@sizeOf(c_int)]);
                        self.rx_fds.append(self.gpa, passed) catch {
                            _ = c.close(passed);
                        };
                    }
                }
            }
            self.in.appendSlice(self.gpa, buf[0..@intCast(n)]) catch {
                self.lost();
                return false;
            };
            budget -|= @intCast(n);
            if (@as(usize, @intCast(n)) < buf.len) break;
        }

        var reader = proto.Reader.init(self.in.items);
        while (true) {
            const frame = (reader.next() catch {
                self.lost();
                return false;
            }) orelse break;
            self.dispatch(frame);
            if (self.fd < 0) return false;
        }
        const used = reader.consumed();
        if (used != 0 and used <= self.in.items.len) {
            const rest = self.in.items.len - used;
            std.mem.copyForwards(u8, self.in.items[0..rest], self.in.items[used..]);
            self.in.shrinkRetainingCapacity(rest);
        }
        return true;
    }

    fn takeFd(self: *Engine) ?c_int {
        if (self.rx_fds.items.len == 0) return null;
        return self.rx_fds.orderedRemove(0);
    }

    fn setOwned(self: *Engine, slot: *?[]u8, text: []const u8) void {
        const owned = self.gpa.dupe(u8, text) catch return;
        if (slot.*) |old| self.gpa.free(old);
        slot.* = owned;
    }

    fn acceptsSemanticReply(v: *View, kind: OpKind, request: u32) bool {
        const ki = @intFromEnum(kind);
        if (!v.legacy_quarantine.consume(ki, request)) return false;
        return v.waiting[ki] and v.waiting_request[ki] == request and v.inbox[ki] == null;
    }

    fn park(self: *Engine, v: *View, kind: OpKind, request: u32, ok: bool, text: []const u8, doc_gen: u32, rev: u32, snap_kind: u8) void {
        if (!acceptsSemanticReply(v, kind, request)) return;
        const ki = @intFromEnum(kind);
        const owned = self.gpa.dupe(u8, text) catch return;
        if (v.inbox[ki]) |old| self.gpa.free(old.text);
        v.inbox[ki] = .{ .ok = ok, .text = owned, .doc_gen = doc_gen, .rev = rev, .snap_kind = snap_kind };
    }

    fn dispatch(self: *Engine, frame: proto.Frame) void {
        switch (frame.tag) {
            .hello_ack => {
                const ack = proto.HelloAck.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ack.caps);
                if (ack.proto != proto.PROTO_VERSION) {
                    self.lost();
                    self.reason = "the browser helper speaks a different protocol version";
                    return;
                }
                self.cap_shm = false;
                self.cap_semantic = false;
                self.cap_reader_ids = false;
                self.cap_semantic_request_ids = false;
                self.cap_view_url = false;
                self.cap_intercept = false;
                self.cap_contexts = false;
                self.cap_contexts_fail_closed = false;
                self.cap_net_policy = false;
                for (ack.caps) |cap| {
                    if (std.mem.eql(u8, cap, proto.CAP_FRAMES_SHM)) self.cap_shm = true;
                    if (std.mem.eql(u8, cap, proto.CAP_SEMANTIC)) self.cap_semantic = true;
                    if (std.mem.eql(u8, cap, proto.CAP_VIEW_CREATE_URL)) self.cap_view_url = true;
                    if (std.mem.eql(u8, cap, proto.CAP_INTERCEPT)) self.cap_intercept = true;
                    if (std.mem.eql(u8, cap, proto.CAP_READER_IDS)) self.cap_reader_ids = true;
                    if (std.mem.eql(u8, cap, proto.CAP_SEMANTIC_REQUEST_IDS)) self.cap_semantic_request_ids = true;
                    if (std.mem.eql(u8, cap, proto.CAP_CONTEXTS)) self.cap_contexts = true;
                    if (std.mem.eql(u8, cap, proto.CAP_CONTEXTS_FAIL_CLOSED)) self.cap_contexts_fail_closed = true;
                    if (std.mem.eql(u8, cap, proto.CAP_NET_POLICY)) self.cap_net_policy = true;
                }
            },
            .frame_buffer => {
                const fb = proto.decode(proto.FrameBuffer, frame.payload) catch return;
                const fd = self.takeFd() orelse return;
                const v = self.findView(fb.view) orelse {
                    _ = c.close(fd);
                    return;
                };
                if (v.buf_fd >= 0) _ = c.close(v.buf_fd);
                v.buf_fd = fd;
                v.buf_w = fb.w;
                v.buf_h = fb.h;
                v.buf_stride = fb.stride;
            },
            .frame_dmabuf => {
                // Headless ozone spawns no GPU process, so this should
                // never arrive; if it does, the planes' descriptors
                // must not leak into this process.
                const f = proto.FrameDmabuf.decodeFrom(frame.payload) catch return;
                var i: u8 = 0;
                while (i < f.nplanes) : (i += 1) {
                    if (self.takeFd()) |fd| _ = c.close(fd);
                }
            },
            .frame_damage => {
                // The rect list is not needed headless: a screenshot
                // reads the whole buffer; only the paint count matters.
                const dmg = proto.FrameDamage.decodeAlloc(frame.payload, self.gpa) catch return;
                self.gpa.free(dmg.rects);
                if (self.findView(dmg.view)) |v| v.frame_gen +%= 1;
            },
            .ev_title => {
                const ev = proto.decode(proto.EvTitle, frame.payload) catch return;
                if (self.findView(ev.view)) |v| self.setOwned(&v.title, ev.title);
            },
            .ev_nav_state => {
                const ev = proto.decode(proto.EvNavState, frame.payload) catch return;
                if (self.findView(ev.view)) |v| {
                    v.can_back = ev.can_back != 0;
                    v.can_fwd = ev.can_fwd != 0;
                    v.loading = ev.loading != 0;
                    if (ev.url.len > 0) self.setOwned(&v.url, ev.url);
                }
            },
            .ev_load => {
                const ev = proto.decode(proto.EvLoad, frame.payload) catch return;
                if (self.findView(ev.view)) |v| {
                    switch (ev.state) {
                        @intFromEnum(proto.LoadState.started) => {
                            v.loading = true;
                            v.reader_guards.invalidate();
                        },
                        @intFromEnum(proto.LoadState.finished), @intFromEnum(proto.LoadState.failed) => {
                            v.loading = false;
                            v.load_seq +%= 1;
                        },
                        else => {},
                    }
                    if (ev.url.len > 0) self.setOwned(&v.url, ev.url);
                }
            },
            .ev_view_create_failed => {
                // The ONLY negative signal a context request produces:
                // `context_create` has no ack, so a view that never
                // came up is how a bad context becomes visible at all.
                const ev = proto.decode(proto.EvViewCreateFailed, frame.payload) catch return;
                if (self.findView(ev.view)) |v| self.setOwned(&v.create_failed, if (ev.reason.len > 0)
                    ev.reason
                else
                    "the browser helper refused the view's identity context");
            },
            .ev_crashed => {
                const ev = proto.decode(proto.EvCrashed, frame.payload) catch return;
                if (self.findView(ev.view)) |v| {
                    self.setOwned(&v.title, "(renderer crashed)");
                    v.reader_guards.invalidate();
                    for (&v.waiting, 0..) |waiting, ki| {
                        if (waiting and v.inbox[ki] == null) self.park(
                            v,
                            @enumFromInt(ki),
                            v.waiting_request[ki],
                            false,
                            "semantic request canceled because the renderer crashed",
                            0,
                            0,
                            0,
                        );
                    }
                }
            },
            .sem_result => {
                const result = proto.decode(proto.SemResult, frame.payload) catch return;
                self.dispatchSemantic(proto.semResultUnwrap(result), result.request);
            },
            .sem_snapshot, .sem_act_result, .sem_expand_result, .sem_query_result, .sem_read_result, .sem_read_ids_result, .sem_eval_result => self.dispatchSemantic(frame, 0),
            .intercept_status => {
                const ev = proto.decode(proto.InterceptStatus, frame.payload) catch return;
                if (self.findView(ev.view)) |v| {
                    v.net_enabled = ev.enabled != 0;
                    v.net_blocked = ev.blocked;
                    v.net_total = ev.total;
                    v.net_rules = ev.rules;
                }
            },
            .intercept_log => {
                const ev = proto.InterceptLog.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ev.entries);
                const v = self.findView(ev.view) orelse return;
                v.net_next_seq = ev.next_seq;
                const json = proto.netLogJson(self.gpa, ev.next_seq, ev.entries) catch return;
                if (v.net_log) |old| self.gpa.free(old);
                v.net_log = json;
                v.net_log_waiting = false;
            },
            .net_log => {
                const ev = proto.NetLog.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ev.entries);
                const v = self.findView(ev.view) orelse return;
                v.net_next_seq = ev.next_seq;
                const json = proto.netLogJson2(self.gpa, ev.next_seq, ev.entries) catch return;
                if (v.net_log) |old| self.gpa.free(old);
                v.net_log = json;
                v.net_log_waiting = false;
            },
            .ev_net_policy => {
                const ev = proto.decode(proto.EvNetPolicy, frame.payload) catch return;
                const v = self.findView(ev.view) orelse return;
                // A stale serial answers for a policy this view no
                // longer runs; ignore it.
                if (v.pol_serial == 0 or ev.serial != v.pol_serial) return;
                if (ev.active == 0) {
                    v.pol_install_failed = true;
                    return;
                }
                v.pol_active = true;
                v.pol_exhausted = ev.exhausted;
                v.pol_requests = ev.requests;
                v.pol_bytes = ev.bytes;
                v.pol_navigations = ev.navigations;
                v.pol_ms_left = ev.ms_left;
                v.pol_denied = ev.denied;
            },
            else => {},
        }
    }

    fn dispatchSemantic(self: *Engine, frame: proto.Frame, request: u32) void {
        switch (frame.tag) {
            .sem_snapshot => {
                const ev = proto.decode(proto.SemSnapshot, frame.payload) catch return;
                const v = self.findView(ev.view) orelse return;
                self.onSnapshot(v, ev, request);
            },
            .sem_act_result => {
                const ev = proto.decode(proto.SemActResult, frame.payload) catch return;
                if (self.findView(ev.view)) |v| self.park(v, .act, request, ev.ok != 0, ev.msg, 0, 0, 0);
            },
            .sem_expand_result => {
                const ev = proto.decode(proto.SemExpandResult, frame.payload) catch return;
                if (self.findView(ev.view)) |v| self.park(v, .expand, request, true, ev.text, 0, 0, 0);
            },
            .sem_query_result => {
                const ev = proto.decode(proto.SemQueryResult, frame.payload) catch return;
                if (self.findView(ev.view)) |v| self.park(v, .query, request, true, ev.payload.s, 0, 0, 0);
            },
            .sem_read_result => {
                const ev = proto.decode(proto.SemReadResult, frame.payload) catch return;
                if (self.findView(ev.view)) |v| self.park(v, .read, request, true, ev.markdown.s, 0, 0, 0);
            },
            .sem_read_ids_result => {
                const ev = proto.SemReadIdsResult.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ev.entities);
                const v = self.findView(ev.view) orelse return;
                if (!acceptsSemanticReply(v, .read, request)) return;
                _ = v.reader_guards.apply(self.gpa, request, ev) catch return;
                const json = reader_model.stringifyWire(self.gpa, ev) catch return;
                defer self.gpa.free(json);
                self.park(v, .read, request, true, json, ev.doc_gen, ev.rev, 0);
            },
            .sem_eval_result => {
                const ev = proto.decode(proto.SemEvalResult, frame.payload) catch return;
                if (self.findView(ev.view)) |v| {
                    if (!acceptsSemanticReply(v, .eval, request)) return;
                    self.setOwned(&v.last_eval, ev.json.s);
                    self.park(v, .eval, request, ev.ok != 0, ev.json.s, 0, 0, 0);
                }
            },
            else => {},
        }
    }

    /// Mirrors webface.onSnapshot: every `sem_snapshot` frame answers a
    /// request now (the helper coalesces spontaneous mutations into its
    /// shadow tree and pushes nothing for them), so a frame nobody is
    /// waiting on — a stray push from a pre-coalescing helper — is
    /// dropped, never buffered.
    fn onSnapshot(self: *Engine, v: *View, ev: proto.SemSnapshot, request: u32) void {
        const full = ev.kind == @intFromEnum(proto.SnapKind.full);
        const waiting = acceptsSemanticReply(v, .snapshot, request);
        if (!waiting or (v.want_full and !full)) return;
        self.park(v, .snapshot, request, true, ev.payload.s, ev.doc_gen, ev.rev, ev.kind);
    }
};

// ---------------------------------------------------------------------
// Tests (pure bookkeeping; no helper is spawned)
// ---------------------------------------------------------------------

test "a snapshot reply is exactly the helper's coalesced answer; strays are dropped" {
    const gpa = std.testing.allocator;
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null);
    defer {
        eng.state = .idle; // no child to reap
        eng.deinit();
    }
    const v = try gpa.create(View);
    v.* = .{ .id = 1, .w = 100, .h = 100 };
    try eng.views.append(gpa, v);

    // Nobody waiting: the frame is dropped, never buffered — the helper
    // owns "what changed since the caller last looked" now, so text
    // concatenated client-side could only duplicate or contradict it.
    eng.onSnapshot(v, .{ .view = 1, .doc_gen = 1, .rev = 2, .kind = @intFromEnum(proto.SnapKind.delta), .payload = .{ .s = "~ [4] changed\n" } }, 0);
    try std.testing.expect(v.inbox[@intFromEnum(OpKind.snapshot)] == null);

    // A waiting caller gets the reply verbatim: ONE delta, not a
    // concatenation with anything that arrived earlier.
    v.waiting[@intFromEnum(OpKind.snapshot)] = true;
    v.waiting_request[@intFromEnum(OpKind.snapshot)] = 0;
    v.want_full = false;
    try v.reader_guards.entries.append(gpa, .{ .id = 7, .doc_gen = 1, .rev = 2, .guard = 70 });
    try std.testing.expectEqual(@as(u64, 70), Engine.readerGuard(v, 7).?.guard);
    try std.testing.expect(Engine.readerGuard(v, 99) == null);
    eng.onSnapshot(v, .{ .view = 1, .doc_gen = 1, .rev = 3, .kind = @intFromEnum(proto.SnapKind.delta), .payload = .{ .s = "delta rev 2->3\n~ [5] more\n" } }, 0);
    const parked = v.inbox[@intFromEnum(OpKind.snapshot)].?;
    try std.testing.expectEqualStrings("delta rev 2->3\n~ [5] more\n", parked.text);
    try std.testing.expectEqual(@as(u32, 3), parked.rev);
    try std.testing.expectEqual(@as(u64, 70), Engine.readerGuard(v, 7).?.guard);
}

test "a full-mode wait is not satisfied by a spontaneous delta" {
    const gpa = std.testing.allocator;
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null);
    defer {
        eng.state = .idle;
        eng.deinit();
    }
    const v = try gpa.create(View);
    v.* = .{ .id = 1, .w = 100, .h = 100 };
    try eng.views.append(gpa, v);
    v.waiting[@intFromEnum(OpKind.snapshot)] = true;
    v.waiting_request[@intFromEnum(OpKind.snapshot)] = 0;
    v.want_full = true;
    eng.onSnapshot(v, .{ .view = 1, .doc_gen = 1, .rev = 2, .kind = @intFromEnum(proto.SnapKind.delta), .payload = .{ .s = "~ [4] x\n" } }, 0);
    try std.testing.expect(v.inbox[@intFromEnum(OpKind.snapshot)] == null);
    eng.onSnapshot(v, .{ .view = 1, .doc_gen = 2, .rev = 1, .kind = @intFromEnum(proto.SnapKind.full), .payload = .{ .s = "[1] document\n" } }, 0);
    const parked = v.inbox[@intFromEnum(OpKind.snapshot)].?;
    try std.testing.expectEqualStrings("[1] document\n", parked.text);
    try std.testing.expectEqual(@as(u8, @intFromEnum(proto.SnapKind.full)), parked.snap_kind);
}

test "correlated replies ignore old request ids and preserve reader provenance" {
    const gpa = std.testing.allocator;
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null);
    defer {
        eng.state = .idle;
        eng.deinit();
    }
    const v = try gpa.create(View);
    v.* = .{ .id = 1, .w = 100, .h = 100 };
    try eng.views.append(gpa, v);

    const ki = @intFromEnum(OpKind.act);
    v.waiting[ki] = true;
    v.waiting_request[ki] = 22;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try proto.encodePayload(gpa, &payload, proto.SemActResult{ .view = 1, .id = 7, .ok = 1, .msg = "old" });
    eng.dispatchSemantic(.{ .tag = .sem_act_result, .payload = payload.items }, 21);
    try std.testing.expect(v.inbox[ki] == null);

    try v.reader_guards.entries.append(gpa, .{ .id = 7, .doc_gen = 3, .rev = 4, .guard = 70 });
    try std.testing.expectEqual(@as(u64, 70), Engine.readerGuard(v, 7).?.guard);
    eng.onSnapshot(v, .{ .view = 1, .doc_gen = 3, .rev = 5, .kind = @intFromEnum(proto.SnapKind.delta), .payload = .{ .s = "delta" } }, 99);
    try std.testing.expectEqual(@as(u64, 70), Engine.readerGuard(v, 7).?.guard);
}

test "legacy timeout quarantine consumes exactly one late reply" {
    var v = View{ .id = 1, .w = 100, .h = 100 };
    const ki = @intFromEnum(OpKind.read);
    v.legacy_quarantine.mark(ki);
    try std.testing.expect(!Engine.acceptsSemanticReply(&v, .read, 0));
    try std.testing.expect(!v.legacy_quarantine.isHeld(ki));
    v.waiting[ki] = true;
    try std.testing.expect(Engine.acceptsSemanticReply(&v, .read, 0));
}

test "wait cleanup tolerates a view destroyed while the operation ran" {
    const gpa = std.testing.allocator;
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null);
    defer {
        eng.state = .idle;
        eng.deinit();
    }
    const v = try gpa.create(View);
    v.* = .{ .id = 1, .w = 100, .h = 100 };
    try eng.views.append(gpa, v);
    const ki = @intFromEnum(OpKind.read);
    v.waiting[ki] = true;
    v.waiting_request[ki] = 9;
    eng.closeView(1);
    eng.finishWait(1, ki, 9, true);
    try std.testing.expectEqual(@as(usize, 0), eng.views.items.len);
}

// ── profiles: an engine socketpaired to a decodable "helper" ──────
//
// The tests above inspect engine STATE; these have to inspect the
// FRAMES, because context publication has no ack and its correctness IS
// the byte order on the wire.

const Pair = struct {
    eng: Engine,
    peer: c_int = -1,
    tmpl: [64]u8 = undefined,
    saved_state: ?[]const u8 = null,
    saved_buf: [4096]u8 = undefined,

    fn init(gpa: std.mem.Allocator) !Pair {
        var self = Pair{ .eng = undefined };
        @memcpy(self.tmpl[0.."/tmp/sketerm-webdrive-XXXXXX".len], "/tmp/sketerm-webdrive-XXXXXX");
        self.tmpl["/tmp/sketerm-webdrive-XXXXXX".len] = 0;
        const made = c.mkdtemp(@ptrCast(&self.tmpl)) orelse return error.SkipZigTest;
        _ = made;
        if (c.getenv("XDG_STATE_HOME")) |old| {
            const s = std.mem.span(@as([*:0]const u8, @ptrCast(old)));
            @memcpy(self.saved_buf[0..s.len], s);
            self.saved_buf[s.len] = 0;
            self.saved_state = self.saved_buf[0..s.len];
        }
        _ = c.setenv("XDG_STATE_HOME", @ptrCast(&self.tmpl), 1);

        var fds: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) != 0) return error.SkipZigTest;
        self.eng = try Engine.init(gpa, "/tmp/webdrive-test", "unit", null);
        self.eng.fd = fds[0];
        // Exactly what startHelper does to the real socket: `ensure`
        // drains the fd on every call, and a blocking one would park
        // there forever with no helper to answer.
        _ = c.fcntl(self.eng.fd, c.F_SETFL, c.O_NONBLOCK);
        self.peer = fds[1];
        self.handshake(true, true);
        return self;
    }

    /// A fresh socket + handshake, as a restarted helper would be:
    /// `lost` closed the old fd, so nothing could be sent over it.
    fn reconnect(self: *Pair) void {
        var fds: [2]c_int = undefined;
        if (c.socketpair(c.AF_UNIX, c.SOCK_STREAM, 0, &fds) != 0) return;
        if (self.peer >= 0) _ = c.close(self.peer);
        if (self.eng.fd >= 0) _ = c.close(self.eng.fd);
        self.eng.fd = fds[0];
        _ = c.fcntl(self.eng.fd, c.F_SETFL, c.O_NONBLOCK);
        self.peer = fds[1];
        self.handshake(true, true);
    }

    /// The scratch state dir, read off THIS copy of the struct (the
    /// mkdtemp result pointed into init's own stack frame).
    fn stateDir(self: *Pair) []const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(&self.tmpl)));
    }

    /// Bring the engine to `.ready` as a fresh helper generation would.
    fn handshake(self: *Pair, contexts: bool, fail_closed: bool) void {
        self.eng.state = .ready;
        self.eng.helper_gen +%= 1;
        self.eng.cap_semantic = true;
        self.eng.cap_view_url = true;
        self.eng.cap_contexts = contexts;
        self.eng.cap_contexts_fail_closed = fail_closed;
    }

    fn deinit(self: *Pair) void {
        self.eng.deinit();
        if (self.peer >= 0) _ = c.close(self.peer);
        if (self.saved_state != null) {
            _ = c.setenv("XDG_STATE_HOME", @ptrCast(&self.saved_buf), 1);
        } else {
            _ = c.unsetenv("XDG_STATE_HOME");
        }
        webprofiles.rmTreeForTest(self.stateDir());
    }

    /// Everything the engine has written since the last drain. MSG_DONTWAIT
    /// rather than an O_NONBLOCK fd: "nothing was written" is an ANSWER
    /// these tests assert, so the read must never be able to block.
    fn drain(self: *Pair, buf: []u8) []const u8 {
        const n = c.recv(self.peer, buf.ptr, buf.len, c.MSG_DONTWAIT);
        return if (n <= 0) buf[0..0] else buf[0..@intCast(n)];
    }
};

/// The frame tags the engine emitted, in order.
fn tagsOf(bytes: []const u8, out: []proto.Tag) []const proto.Tag {
    var reader = proto.Reader.init(bytes);
    var n: usize = 0;
    while (n < out.len) {
        const frame = (reader.next() catch break) orelse break;
        out[n] = frame.tag;
        n += 1;
    }
    return out[0..n];
}

test "a profile is refused, opening nothing, unless BOTH context caps are advertised" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    var buf: [8192]u8 = undefined;

    // No contexts at all: an old helper (and the smoke fake).
    p.eng.cap_contexts = false;
    p.eng.cap_contexts_fail_closed = false;
    try std.testing.expectError(error.ContextsUnsupported, p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "work" }, null));
    try std.testing.expectError(error.ContextsUnsupported, p.eng.openViewIn("https://x.test/", 800, 600, .ephemeral, null));

    // CAP_CONTEXTS alone is WORSE than none: such a helper resolves an
    // unknown context through the shared jar and never says so.
    p.eng.cap_contexts = true;
    try std.testing.expectError(error.ContextsUnsupported, p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "work" }, null));

    // Fail closed means exactly this: no view, and not one byte on the
    // wire — the requested page never touched the shared cookie jar.
    try std.testing.expectEqual(@as(usize, 0), p.eng.views.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);

    // An invalid name is refused on its own, after the caps pass.
    p.eng.cap_contexts_fail_closed = true;
    try std.testing.expectError(error.InvalidName, p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "Default Jar" }, null));
    try std.testing.expectError(error.InvalidName, p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "default" }, null));
    try std.testing.expectEqual(@as(usize, 0), p.eng.views.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);
}

test "a named open publishes its context BEFORE the view, and republishes the same id after a helper restart" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    var buf: [8192]u8 = undefined;

    const v = try p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "work" }, null);
    const id = v.context;
    try std.testing.expect(id != 0);
    try std.testing.expect(id < webprofiles.EPHEMERAL_BASE);
    try std.testing.expectEqualStrings("work", v.profile.?);
    try std.testing.expect(!v.ephemeral_ctx);

    {
        const bytes = p.drain(&buf);
        var reader = proto.Reader.init(bytes);
        // Order IS the contract: no ack exists, so the helper must see
        // context_create first simply because it arrived first.
        const first = (try reader.next()).?;
        try std.testing.expectEqual(proto.Tag.context_create, first.tag);
        const cc = try proto.decode(proto.ContextCreate, first.payload);
        try std.testing.expectEqual(id, cc.id);
        try std.testing.expectEqual(@as(u8, 0), cc.ephemeral);
        try std.testing.expectEqualStrings("profile-work", cc.name);
        try std.testing.expectEqualStrings("", cc.proxy);
        const second = (try reader.next()).?;
        try std.testing.expectEqual(proto.Tag.view_create_url, second.tag);
        const vc = try proto.decode(proto.ViewCreateUrl, second.payload);
        try std.testing.expectEqual(id, vc.context);
    }

    // A SECOND view in the same profile costs no re-create.
    const v2 = try p.eng.openViewIn("https://y.test/", 800, 600, .{ .named = "work" }, null);
    try std.testing.expectEqual(id, v2.context);
    {
        var tag_buf: [8]proto.Tag = undefined;
        const tags = tagsOf(p.drain(&buf), &tag_buf);
        try std.testing.expectEqual(@as(usize, 2), tags.len);
        try std.testing.expectEqual(proto.Tag.view_create_url, tags[0]);
    }

    // The helper crashed: views and published contexts are gone, but
    // the PERSISTED id is not — the same jar comes back.
    p.eng.lost();
    try std.testing.expectEqual(@as(usize, 0), p.eng.views.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.eng.live.items.len);
    p.reconnect();
    const after = try p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "work" }, null);
    try std.testing.expectEqual(id, after.context);
    {
        const bytes = p.drain(&buf);
        var reader = proto.Reader.init(bytes);
        const first = (try reader.next()).?;
        try std.testing.expectEqual(proto.Tag.context_create, first.tag);
        try std.testing.expectEqual(id, (try proto.decode(proto.ContextCreate, first.payload)).id);
    }
}

test "ephemeral contexts get their own id space and die with their last view" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    var buf: [8192]u8 = undefined;

    const a = try p.eng.openViewIn("https://a.test/", 800, 600, .ephemeral, null);
    const b = try p.eng.openViewIn("https://b.test/", 800, 600, .ephemeral, null);
    try std.testing.expect(a.context != b.context);
    try std.testing.expect(a.context >= webprofiles.EPHEMERAL_BASE);
    try std.testing.expect(b.context >= webprofiles.EPHEMERAL_BASE);
    try std.testing.expect(a.profile == null and a.ephemeral_ctx);
    // A throwaway identity is never persisted: the store stays empty.
    try std.testing.expectEqual(@as(usize, 0), p.eng.store.?.list().len);
    _ = p.drain(&buf);

    // Closing one ephemeral view destroys exactly ITS context.
    p.eng.closeView(a.id);
    {
        var tag_buf: [8]proto.Tag = undefined;
        const tags = tagsOf(p.drain(&buf), &tag_buf);
        try std.testing.expectEqual(@as(usize, 2), tags.len);
        try std.testing.expectEqual(proto.Tag.view_destroy, tags[0]);
        try std.testing.expectEqual(proto.Tag.context_destroy, tags[1]);
    }

    // A NAMED profile's close destroys no context: its storage is the
    // point, and a later open must not pay a re-create.
    const named = try p.eng.openViewIn("https://n.test/", 800, 600, .{ .named = "work" }, null);
    _ = p.drain(&buf);
    p.eng.closeView(named.id);
    {
        var tag_buf: [8]proto.Tag = undefined;
        const tags = tagsOf(p.drain(&buf), &tag_buf);
        try std.testing.expectEqual(@as(usize, 1), tags.len);
        try std.testing.expectEqual(proto.Tag.view_destroy, tags[0]);
    }
    try std.testing.expectEqual(@as(u32, 0), p.eng.profileViewCount("work"));
}

test "ev_view_create_failed marks the view and its close rolls the context back" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    var buf: [8192]u8 = undefined;

    const v = try p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "work" }, null);
    _ = p.drain(&buf);
    try std.testing.expect(v.create_failed == null);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try proto.encodePayload(gpa, &payload, proto.EvViewCreateFailed{
        .view = v.id,
        .context = v.context,
        .reason = "requested browser context does not exist",
    });
    p.eng.dispatch(.{ .tag = .ev_view_create_failed, .payload = payload.items });
    try std.testing.expectEqualStrings("requested browser context does not exist", v.create_failed.?);

    // The tool closes the doomed view; the refcount must go back to 0
    // or the profile would look permanently in use.
    p.eng.closeView(v.id);
    try std.testing.expectEqual(@as(u32, 0), p.eng.profileViewCount("work"));
    for (p.eng.live.items) |ctx| {
        if (std.mem.eql(u8, ctx.name, "work")) try std.testing.expectEqual(@as(u32, 0), ctx.views);
    }
}

test "resetProfile refuses a profile in use and retires its id when free" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    var buf: [8192]u8 = undefined;

    const v = try p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "work" }, null);
    const id = v.context;
    _ = p.drain(&buf);
    try std.testing.expectError(error.InUse, p.eng.resetProfile("work"));
    try std.testing.expectError(error.NoProfile, p.eng.resetProfile("never-used"));
    try std.testing.expectError(error.InvalidName, p.eng.resetProfile("Bad Name"));

    p.eng.closeView(v.id);
    _ = p.drain(&buf);
    try std.testing.expectEqual(id, try p.eng.resetProfile("work"));
    {
        var tag_buf: [8]proto.Tag = undefined;
        const tags = tagsOf(p.drain(&buf), &tag_buf);
        try std.testing.expectEqual(@as(usize, 1), tags.len);
        try std.testing.expectEqual(proto.Tag.context_destroy, tags[0]);
    }

    // The name stays usable and comes back on a DIFFERENT id, so a
    // half-failed erase can never resurface as this profile's cookies.
    const fresh = try p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "work" }, null);
    try std.testing.expect(fresh.context != id);
}

test "profile listing reports store and live state without spawning a helper" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buf: [8192]u8 = undefined;

    try std.testing.expectEqual(@as(usize, 0), (try p.eng.profileList(arena)).len);
    try std.testing.expect(p.eng.profilesAvailable());
    try std.testing.expectEqualStrings("", p.eng.profileUnavailableReason());
    try std.testing.expect(p.eng.profileStorePath() != null);

    const v = try p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "work" }, null);
    _ = p.drain(&buf);
    const listed = try p.eng.profileList(arena);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("work", listed[0].name);
    try std.testing.expectEqual(@as(u32, 1), listed[0].views);
    try std.testing.expect(listed[0].live);
    try std.testing.expect(listed[0].last_used_ms != 0);

    p.eng.closeView(v.id);
    try std.testing.expectEqual(@as(u32, 0), (try p.eng.profileList(arena))[0].views);

    // A helper without the caps makes profiles unavailable, and SAYS so.
    p.eng.cap_contexts_fail_closed = false;
    try std.testing.expect(!p.eng.profilesAvailable());
    try std.testing.expect(std.mem.indexOf(u8, p.eng.profileUnavailableReason(), "contexts-fail-closed") != null);
}

test "the current view is the last one touched, not the oldest" {
    const gpa = std.testing.allocator;
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null);
    defer {
        eng.state = .idle; // no child to reap
        eng.deinit();
    }
    // Two views, as two `web_open` calls would leave them. openView
    // itself needs a live helper, so mint them the way it does.
    for ([_]u32{ 1, 2 }) |id| {
        const v = try gpa.create(View);
        v.* = .{ .id = id, .w = 100, .h = 100 };
        try eng.views.append(gpa, v);
        eng.current = id;
    }
    // A handle-less call means the newest, not views.items[0]: the
    // oldest-view fallback made a second web_open look like it had
    // dropped its url, because every later call still read view 1.
    try std.testing.expectEqual(@as(u32, 2), eng.current);

    // Addressing one explicitly moves "current" onto it.
    eng.setCurrent(1);
    try std.testing.expectEqual(@as(u32, 1), eng.current);

    // An unknown id must not strand `current` on a view that is gone.
    eng.setCurrent(99);
    try std.testing.expectEqual(@as(u32, 1), eng.current);

    // Closing the current view hands it to the newest survivor.
    eng.closeView(1);
    try std.testing.expectEqual(@as(u32, 2), eng.current);
    eng.closeView(2);
    try std.testing.expectEqual(@as(u32, 0), eng.current);
}

test "a policied open is refused, opening nothing, without the net-policy capability" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    var buf: [8192]u8 = undefined;

    const pol = NetPolicy{ .allow_top = &.{"site.example"}, .max_requests = 10 };
    try std.testing.expect(!p.eng.cap_net_policy);
    try std.testing.expectError(error.PolicyUnsupported, p.eng.openViewIn("https://site.example/", 800, 600, .default, &pol));
    // Fail closed: no view, and not one byte on the wire — the page was
    // never loaded unpoliced.
    try std.testing.expectEqual(@as(usize, 0), p.eng.views.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);
}

test "net_policy_set travels strictly before view_create_url, naming the same view" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.cap_net_policy = true;
    var buf: [16384]u8 = undefined;

    const pol = NetPolicy{ .allow_top = &.{"site.example"}, .max_requests = 5, .block_ads = true };
    const v = try p.eng.openViewIn("https://site.example/", 800, 600, .default, &pol);
    try std.testing.expect(v.pol != null);
    try std.testing.expect(v.pol_serial != 0);

    const bytes = p.drain(&buf);
    var reader = proto.Reader.init(bytes);
    // Frame order IS the install-before-first-request guarantee.
    const f1 = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.net_policy_set, f1.tag);
    const set = try proto.NetPolicySet.decodeAlloc(f1.payload, gpa);
    defer gpa.free(set.allow_top);
    defer gpa.free(set.allow_sub);
    try std.testing.expectEqual(v.id, set.view);
    try std.testing.expectEqual(v.pol_serial, set.serial);
    try std.testing.expectEqual(@as(u32, 5), set.max_requests);
    try std.testing.expectEqualStrings("site.example", set.allow_top[0]);
    // block_ads:true rides the EXISTING per-view shield switch.
    const f2 = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.intercept_set, f2.tag);
    const f3 = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.view_create_url, f3.tag);
    const create = try proto.decode(proto.ViewCreateUrl, f3.payload);
    try std.testing.expectEqual(v.id, create.view);
}

test "ev_net_policy: a stale serial is ignored, the live one updates, active=0 fails the install" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.cap_net_policy = true;
    var buf: [16384]u8 = undefined;

    const pol = NetPolicy{ .allow_top = &.{"site.example"} };
    const v = try p.eng.openViewIn("https://site.example/", 800, 600, .default, &pol);
    _ = p.drain(&buf);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    var denied: [proto.NREASONS]u32 = @splat(0);
    denied[@intFromEnum(proto.NetReason.sub_host)] = 3;
    // A stale serial (an earlier policy's echo) must change nothing.
    try proto.encodePayload(gpa, &payload, proto.EvNetPolicy{
        .view = v.id,
        .serial = v.pol_serial + 100,
        .active = 1,
        .exhausted = @intFromEnum(proto.NetReason.request_cap),
        .requests = 99,
        .bytes = 9,
        .navigations = 9,
        .ms_left = 0,
        .denied = denied,
    });
    p.eng.dispatch(.{ .tag = .ev_net_policy, .payload = payload.items });
    try std.testing.expectEqual(@as(u32, 0), v.pol_requests);
    try std.testing.expectEqual(@as(u8, 0), v.pol_exhausted);

    payload.clearRetainingCapacity();
    try proto.encodePayload(gpa, &payload, proto.EvNetPolicy{
        .view = v.id,
        .serial = v.pol_serial,
        .active = 1,
        .exhausted = @intFromEnum(proto.NetReason.request_cap),
        .requests = 42,
        .bytes = 1234,
        .navigations = 2,
        .ms_left = 0,
        .denied = denied,
    });
    p.eng.dispatch(.{ .tag = .ev_net_policy, .payload = payload.items });
    try std.testing.expectEqual(@as(u32, 42), v.pol_requests);
    try std.testing.expectEqual(@as(u64, 1234), v.pol_bytes);
    try std.testing.expectEqual(@intFromEnum(proto.NetReason.request_cap), v.pol_exhausted);
    try std.testing.expectEqual(@as(u32, 3), v.pol_denied[@intFromEnum(proto.NetReason.sub_host)]);

    // active=0 for OUR serial: the helper could not hold the policy.
    payload.clearRetainingCapacity();
    try proto.encodePayload(gpa, &payload, proto.EvNetPolicy{
        .view = v.id,
        .serial = v.pol_serial,
        .active = 0,
        .exhausted = 0,
        .requests = 0,
        .bytes = 0,
        .navigations = 0,
        .ms_left = 0,
        .denied = @splat(0),
    });
    p.eng.dispatch(.{ .tag = .ev_net_policy, .payload = payload.items });
    try std.testing.expect(v.pol_install_failed);
}

test "a live policy only tightens: loosenings are named and never sent" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.cap_net_policy = true;
    var buf: [16384]u8 = undefined;

    const pol = NetPolicy{
        .allow_top = &.{ "site.example", "cdn.example" },
        .max_requests = 100,
        .max_bytes = 1000,
    };
    const v = try p.eng.openViewIn("https://site.example/", 800, 600, .default, &pol);
    _ = p.drain(&buf);
    const first_serial = v.pol_serial;

    // Pure loosening: more hosts, higher budget. Nothing may move and
    // nothing may be sent.
    const looser = NetPolicyPatch{
        .allow_top = &.{ "site.example", "cdn.example", "extra.example" },
        .max_requests = 5000,
    };
    const r1 = try p.eng.tightenViewPolicy(v.id, &looser);
    try std.testing.expectEqual(@as(usize, 0), r1.n_tightened);
    try std.testing.expect(r1.n_ignored >= 2);
    try std.testing.expectEqual(first_serial, v.pol_serial);
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);
    try std.testing.expectEqual(@as(usize, 2), v.pol.?.allow_top.len);

    // A real tighten: fewer hosts, lower budget — re-sent with a new
    // serial, and the mixed-in loosening is still named.
    const tighter = NetPolicyPatch{
        .allow_top = &.{"site.example"},
        .max_requests = 10,
        .max_bytes = 5000, // looser: ignored
    };
    const r2 = try p.eng.tightenViewPolicy(v.id, &tighter);
    try std.testing.expect(r2.n_tightened >= 2);
    try std.testing.expect(r2.n_ignored >= 1);
    try std.testing.expect(v.pol_serial != first_serial);
    try std.testing.expectEqual(@as(usize, 1), v.pol.?.allow_top.len);
    try std.testing.expectEqual(@as(u32, 10), v.pol.?.max_requests);
    try std.testing.expectEqual(@as(u64, 1000), v.pol.?.max_bytes);
    const bytes = p.drain(&buf);
    var reader = proto.Reader.init(bytes);
    const frame = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.net_policy_set, frame.tag);
    const set = try proto.NetPolicySet.decodeAlloc(frame.payload, gpa);
    defer gpa.free(set.allow_top);
    defer gpa.free(set.allow_sub);
    try std.testing.expectEqual(v.pol_serial, set.serial);
    try std.testing.expectEqual(@as(usize, 1), set.allow_top.len);
}

test "a partial tighten leaves every omitted field exactly as it was" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.cap_net_policy = true;
    var buf: [16384]u8 = undefined;

    const all_schemes = netpolicy.default_schemes | netpolicy.schemeBit("ws").? | netpolicy.schemeBit("wss").?;
    const pol = NetPolicy{
        .allow_top = &.{"site.example"},
        .allow_schemes = all_schemes,
        .allow_private = true,
        .max_requests = 100,
        .max_bytes = 1000,
    };
    const v = try p.eng.openViewIn("https://site.example/", 800, 600, .default, &pol);
    _ = p.drain(&buf);

    // Only max_requests is said: schemes and private access must survive.
    const r = try p.eng.tightenViewPolicy(v.id, &.{ .max_requests = 10 });
    try std.testing.expectEqual(@as(usize, 1), r.n_tightened);
    try std.testing.expectEqualStrings("max_requests", r.tightened[0]);
    try std.testing.expectEqual(@as(usize, 0), r.n_ignored);
    try std.testing.expectEqual(all_schemes, v.pol.?.allow_schemes);
    try std.testing.expect(v.pol.?.allow_private);
    try std.testing.expectEqual(@as(u32, 10), v.pol.?.max_requests);
    try std.testing.expectEqual(@as(u64, 1000), v.pol.?.max_bytes);
    try std.testing.expectEqual(@as(usize, 1), v.pol.?.allow_top.len);

    // The frame that went out carries the untouched fields too.
    const bytes = p.drain(&buf);
    var reader = proto.Reader.init(bytes);
    const frame = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.net_policy_set, frame.tag);
    const set = try proto.NetPolicySet.decodeAlloc(frame.payload, gpa);
    defer gpa.free(set.allow_top);
    defer gpa.free(set.allow_sub);
    try std.testing.expectEqual(all_schemes, set.allow_schemes);
    try std.testing.expect(set.flags & proto.NetPolicySet.flag_allow_private != 0);

    // An empty patch moves nothing and sends nothing.
    const r0 = try p.eng.tightenViewPolicy(v.id, &.{});
    try std.testing.expectEqual(@as(usize, 0), r0.n_tightened);
    try std.testing.expectEqual(@as(usize, 0), r0.n_ignored);
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);
}

test "explicit scheme and private-address fields still tighten, and widen attempts are named" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.cap_net_policy = true;
    var buf: [16384]u8 = undefined;

    const ws = netpolicy.schemeBit("ws").?;
    const pol = NetPolicy{
        .allow_top = &.{"site.example"},
        .allow_schemes = netpolicy.default_schemes | ws,
        .allow_private = true,
        .max_requests = 100,
    };
    const v = try p.eng.openViewIn("https://site.example/", 800, 600, .default, &pol);
    _ = p.drain(&buf);

    // Explicit shrink of schemes, explicit private off: both tighten.
    const r1 = try p.eng.tightenViewPolicy(v.id, &.{
        .allow_schemes = netpolicy.default_schemes,
        .allow_private = false,
    });
    try std.testing.expectEqual(@as(usize, 2), r1.n_tightened);
    try std.testing.expectEqual(@as(usize, 0), r1.n_ignored);
    try std.testing.expectEqual(netpolicy.default_schemes, v.pol.?.allow_schemes);
    try std.testing.expect(!v.pol.?.allow_private);
    try std.testing.expectEqual(@as(u32, 100), v.pol.?.max_requests);
    _ = p.drain(&buf);

    // Every widening at once: more hosts, a scheme back, private back on,
    // a higher budget, an "unbounded" budget. All named, nothing moves,
    // nothing is sent.
    const r2 = try p.eng.tightenViewPolicy(v.id, &.{
        .allow_top = &.{ "site.example", "extra.example" },
        .allow_schemes = netpolicy.default_schemes | ws,
        .allow_private = true,
        .max_requests = 500,
        .max_bytes = 0,
    });
    try std.testing.expectEqual(@as(usize, 0), r2.n_tightened);
    const want_ignored = [_][]const u8{ "allow_hosts", "allow_schemes", "allow_private_addresses", "max_requests" };
    try std.testing.expectEqual(want_ignored.len, r2.n_ignored);
    for (want_ignored) |name| {
        var found = false;
        for (r2.ignored[0..r2.n_ignored]) |n| {
            if (std.mem.eql(u8, n, name)) found = true;
        }
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);
    try std.testing.expectEqual(netpolicy.default_schemes, v.pol.?.allow_schemes);
    try std.testing.expect(!v.pol.?.allow_private);
    try std.testing.expectEqual(@as(u32, 100), v.pol.?.max_requests);

    // Explicit 0 on a BOUNDED budget is a loosening and is named.
    const r3 = try p.eng.tightenViewPolicy(v.id, &.{ .max_requests = 0 });
    try std.testing.expectEqual(@as(usize, 0), r3.n_tightened);
    try std.testing.expectEqual(@as(usize, 1), r3.n_ignored);
    try std.testing.expectEqualStrings("max_requests", r3.ignored[0]);
}

test "NetPolicyPatch.effective fills open-time defaults only for omitted fields" {
    const empty = (NetPolicyPatch{}).effective();
    try std.testing.expectEqual(netpolicy.default_schemes, empty.allow_schemes);
    try std.testing.expect(!empty.allow_private);
    try std.testing.expectEqual(@as(u32, 0), empty.max_requests);
    const ws = netpolicy.schemeBit("ws").?;
    const said = (NetPolicyPatch{ .allow_schemes = ws, .allow_private = true, .max_bytes = 7 }).effective();
    try std.testing.expectEqual(ws, said.allow_schemes);
    try std.testing.expect(said.allow_private);
    try std.testing.expectEqual(@as(u64, 7), said.max_bytes);
}

test "a profile's session-default policy rides its web_open, and only its own" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.cap_net_policy = true;
    var buf: [16384]u8 = undefined;

    const pol = NetPolicy{ .allow_top = &.{"site.example"}, .max_requests = 7 };
    try p.eng.setProfilePolicy("work", &pol);
    try std.testing.expect(p.eng.profilePolicy("work") != null);

    const v = try p.eng.openViewIn("https://site.example/", 800, 600, .{ .named = "work" }, null);
    try std.testing.expect(v.pol != null);
    try std.testing.expectEqual(@as(u32, 7), v.pol.?.max_requests);
    const bytes = p.drain(&buf);
    var tags: [8]proto.Tag = undefined;
    const seen = tagsOf(bytes, &tags);
    // context_create (the profile) first, then the policy, then the view.
    try std.testing.expectEqual(proto.Tag.context_create, seen[0]);
    try std.testing.expectEqual(proto.Tag.net_policy_set, seen[1]);
    try std.testing.expectEqual(proto.Tag.view_create_url, seen[2]);

    // A different profile (and the default jar) stays unpoliced.
    const other = try p.eng.openViewIn("https://site.example/", 800, 600, .{ .named = "personal" }, null);
    try std.testing.expect(other.pol == null);
    const plain = try p.eng.openViewIn("https://site.example/", 800, 600, .default, null);
    try std.testing.expect(plain.pol == null);
}
