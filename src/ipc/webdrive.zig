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
//! that buys: the helper PRESENTS every page view as a real Wayland
//! toplevel on that hub (`src/web/presenter.zig`, armed through
//! `SKETERM_WEB_PRESENTER=1` in the helper's environment, advertised
//! back as the `presenter` capability), so an attached viewer sees the
//! assistant's pages as windows, page audio reaches the session's
//! Pulse server, and a viewer holding the controller lease drives the
//! page with its own pointer and keyboard. The session is enumerable,
//! attachable, and its lifetime tracks the helper's. `presenterActive`
//! is the fact `capabilities` reports as `web_watch`.
//!
//! Session setup is best-effort with an automatic fallback: any
//! failure — no daemon, an old daemon, a helper that cannot even start
//! against the session's compositor — lands in the plain headless mode
//! that existed before (`--ozone-platform=headless`), and a
//! startup-with-session failure latches so the tools never flap.
//! `SKETERM_WEB_SESSION=0` opts out entirely. A leaked session (MCP
//! SIGKILL) is reaped by its own 60s no-client TTL.
//!
//! ## One engine per ROUTE
//!
//! A browser route (`src/web/route.zig`) is realized as a whole helper
//! INSTANCE, never as a proxy inside one: CEF cannot give two
//! storage-sharing contexts two egress routes. An Engine therefore
//! carries a `route` and everything an instance owns is derived from
//! its `Spec.slug`: the helper socket, the spawn lock, the presence
//! file, the profile store root and the `--proxy` the helper is started
//! with. The DIRECT route keeps the pre-route names byte for byte
//! (`web.sock`, `web.json`, the plain instance store), so an upgrade
//! strands no existing profile; every other route gets `web-<slug>.*`
//! and a store root of its own. `capabilities` reports which route
//! kinds this backend can realize as `web_routes`.
//!
//! ## Discoverability
//!
//! The helper socket lives at the WELL-KNOWN name `web.sock` inside the
//! MCP instance directory (`$XDG_RUNTIME_DIR/sketerm/mcp-tmp-<pid>/` or
//! `mcp-<name>/`), next to a presence file `web.json` (a routed engine
//! writes its own `web-<slug>.json` beside it, so two engines of one
//! instance never clobber each other's record):
//!   {"mcp_pid":N,"helper_pid":N,"client":"sketerm-mcp[:name]","started_at_ms":N,
//!    "session":"web-...","mux_socket":"..."}
//! (the last two only in session mode) written when the helper comes up
//! and unlinked with it, so a GUI can enumerate assistant browser
//! sessions by scanning the instance dirs. Watching is done through
//! the SESSION (attach a viewer; the presenter's toplevels are there),
//! never through a second client on `web.sock`: the helper serves
//! several clients, but every view is scoped to the connection that
//! created it and no client can address another's.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const pathz = @import("../util/pathz.zig");
const strz = @import("../util/strz.zig");
const muxclient = @import("../mux/client.zig");
const fsserve = @import("../mux/fsserve.zig");
const display = @import("../mux/display.zig");
const proto = @import("../web/protocol.zig");
const navfault = @import("../web/navfault.zig");
const reader_model = @import("../web/reader.zig");
const reader_guards = @import("../web/reader_guards.zig");
const findbin = @import("../web/findbin.zig");
const png = @import("../util/png.zig");
const quarantine = @import("../web/quarantine.zig");
const clock = @import("../util/clock.zig");
const webprofiles = @import("webprofiles.zig");
const webremote = @import("webprofilesremote.zig");
const netpolicy = @import("../web/netpolicy.zig");
const webroute = @import("../web/route.zig");

/// Default logical size a headless view is created at. There is no
/// allocation to inherit one from, and pages lay out sanely at a
/// laptop-ish viewport.
pub const DEFAULT_W: u16 = 1280;
pub const DEFAULT_H: u16 = 800;

/// How long a freshly spawned helper gets to bind its socket. CEF's
/// startup (re-exec, zygote) dominates; matches the GUI's 150x100ms.
const SPAWN_WAIT_MS: i64 = 15_000;

/// How long `ensure` waits for a SIBLING client's in-flight spawn
/// (the `web.lock` flock) before proceeding without it. Must exceed a
/// worst-case spawn + handshake so the second client adopts the first
/// one's helper instead of racing it.
const SPAWN_LOCK_WAIT_MS: i64 = 30_000;

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
    /// Eval only: how many characters of a STRING inside the result the
    /// page-side serializer may emit before it marks a cut (0 = its own
    /// default). The caller's inline budget, not a wire constant.
    max_str: u32 = 0,
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

    /// Bounded mirror of the page's `ev_console` stream, so a tool can
    /// answer "what did the page log" after the fact. Drop-oldest; ids
    /// keep increasing so a reader can page with `since`.
    console: std.ArrayList(ConsoleLine) = .empty,
    console_next_id: u32 = 1,
    console_dropped: u32 = 0,

    /// The certificate verdict on this view's current navigation
    /// (`ev_cert_error`). This driver ANSWERS the hold itself, so a view
    /// here is never "pending": it is refused (the default, fail closed)
    /// or accepted (`accept_fingerprint` matched). Cleared by the next
    /// started load, except an accepted one on the same host, which is
    /// what the loaded page stands on and must keep saying so.
    cert: ?navfault.CertRec = null,
    /// The last main-frame load failure (`ev_load_error`), cleared by
    /// the next started load. A refused certificate produces one too,
    /// so `cert` explains it.
    load_error: ?navfault.LoadErrRec = null,
    /// SHA-256 (lowercase hex) of the ONE certificate this view may
    /// proceed on. Every other certificate error is refused; nothing is
    /// remembered engine-side either (`proto.CertDecision`). Owned.
    accept_fingerprint: ?[]u8 = null,

    fn deinit(self: *View, gpa: std.mem.Allocator) void {
        for (self.console.items) |line| gpa.free(line.text);
        self.console.deinit(gpa);
        if (self.cert) |*rec| rec.free(gpa);
        if (self.load_error) |*rec| rec.free(gpa);
        if (self.accept_fingerprint) |f| gpa.free(f);
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

/// One download this engine is tracking — a page-initiated one, or one
/// `startDownload` asked for.
///
/// The client, not the engine, decides where bytes land: an offer is
/// HELD helper-side until a `download_decide` names a path, so this
/// record exists from the moment the offer arrives. A headless client
/// that ignored those frames is exactly how a download silently went
/// nowhere — the engine held the target decision forever, the page saw
/// a perfectly successful `a.click()`, and no file was ever written.
pub const Download = struct {
    /// Client-minted request id; `startDownload` returns it and every
    /// status lookup takes it. A page-initiated download gets one too,
    /// so both kinds are addressable the same way.
    req: u32,
    /// Engine download id, once the offer arrived; 0 before that.
    id: u32 = 0,
    view: u32,
    /// Requested source url (`startDownload`), or the offer's url.
    /// Owned.
    url: []u8,
    /// Suggested file name from the offer; owned, empty until then.
    name: []u8 = &.{},
    /// Where the bytes are being written; owned.
    path: []u8 = &.{},
    mime: []u8 = &.{},
    received: u64 = 0,
    total: u64 = 0,
    started_ms: i64 = 0,
    /// Set once a terminal frame arrived. `done` and `failed` are
    /// exclusive; both false = still running (or still held).
    done: bool = false,
    failed: bool = false,
    /// Why it failed, for the caller's sentence. Static strings.
    fail_reason: []const u8 = "",
    /// The offer arrived and a path was sent back.
    decided: bool = false,

    pub fn terminal(self: *const Download) bool {
        return self.done or self.failed;
    }

    fn deinit(self: *Download, gpa: std.mem.Allocator) void {
        gpa.free(self.url);
        if (self.name.len != 0) gpa.free(self.name);
        if (self.path.len != 0) gpa.free(self.path);
        if (self.mime.len != 0) gpa.free(self.mime);
    }
};

pub const DownloadError = error{
    Unavailable,
    NoView,
    Unsupported,
    OutOfMemory,
    BadPath,
};

pub const ConsoleLine = struct { id: u32, level: u8, text: []u8 };

/// Console mirror bounds: entries kept per view, bytes kept per line.
pub const CONSOLE_CAP = 200;
pub const CONSOLE_LINE_MAX = 512;

pub const State = enum { idle, ready, unavailable };

/// Who started the engine this client talks to. THE vocabulary behind
/// the `web_engine_owner` capability fact: `capabilities` names the
/// member, consumers must never have to fingerprint it from side
/// effects (the broker lane was inferred through profile behaviour
/// once; this is the answer to that).
pub const Owner = enum {
    /// Not connected to any engine yet.
    none,
    /// The mux broker spawned it (`web_op engine_open`): linger
    /// lifecycle, survives this client's exit and restart.
    broker,
    /// This process forked it; it exits with its last client.
    self_spawned,
    /// A live engine another client of this instance started; its
    /// lifecycle is whoever started it.
    adopted,

    pub fn name(self: Owner) []const u8 {
        return switch (self) {
            .none => "none",
            .broker => "broker",
            .self_spawned => "self",
            .adopted => "adopted",
        };
    }
};

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

/// A policy as a CLIENT WROTE it: EVERY field remembers whether it was
/// supplied (null = not said). `effective()` fills the open-time defaults
/// for a fresh policy; `tightenViewPolicy` reads presence directly, so an
/// omitted field can never be mistaken for a request to tighten to its
/// default (the way a bare `NetPolicy{}` once reset a live view's schemes
/// to http+https and its allow_private to off). The shape is pinned at
/// comptime against `NetPolicy`: one field per policy field, same name,
/// optional-wrapped, defaulting to null — so a policy field added without
/// its patch counterpart, or a patch field written "empty = absent"
/// style, is a compile error rather than a silently dropped field.
/// Consequence for host lists: a PRESENT empty list means what it says.
/// At open time `effective()` hands web_open an empty allow-list and it
/// defaults to the url's host as before; at tighten time it narrows the
/// view to NO hosts, the one monotone reading there is.
pub const NetPolicyPatch = struct {
    allow_top: ?[]const []const u8 = null,
    allow_sub: ?[]const []const u8 = null,
    block_types: ?u16 = null,
    allow_schemes: ?u16 = null,
    allow_private: ?bool = null,
    block_ads: ?bool = null,
    max_requests: ?u32 = null,
    max_bytes: ?u64 = null,
    max_navigations: ?u32 = null,
    deadline_ms: ?u32 = null,

    comptime {
        assertMirrorsPolicy();
    }

    /// Build-time drift gate: the patch has exactly `NetPolicy`'s field
    /// set, each wrapped in `?` (a policy field that is ALREADY optional,
    /// like `block_ads`, keeps its type: its null already means "leave
    /// alone"), and each defaulting to null. A patch field that is not
    /// optional would be the "empty = nothing said" special case this
    /// type exists to remove, so it fails the build.
    fn assertMirrorsPolicy() void {
        const policy_fields = std.meta.fields(NetPolicy);
        const patch_fields = std.meta.fields(NetPolicyPatch);
        if (policy_fields.len != patch_fields.len)
            @compileError("NetPolicyPatch must carry exactly NetPolicy's fields (a patch field without a policy counterpart is never applied)");
        inline for (policy_fields) |pf| {
            if (!@hasField(NetPolicyPatch, pf.name))
                @compileError("NetPolicy." ++ pf.name ++ " has no NetPolicyPatch counterpart: effective() would silently drop it on the web_open path");
            const want: type = if (@typeInfo(pf.type) == .optional) pf.type else ?pf.type;
            const got: type = @FieldType(NetPolicyPatch, pf.name);
            if (got != want)
                @compileError("NetPolicyPatch." ++ pf.name ++ " must be " ++ @typeName(want) ++ " (null = not said), found " ++ @typeName(got));
        }
        inline for (patch_fields) |qf| {
            const dflt = qf.defaultValue() orelse
                @compileError("NetPolicyPatch." ++ qf.name ++ " needs a null default");
            if (dflt != null)
                @compileError("NetPolicyPatch." ++ qf.name ++ " must default to null: an omitted field says nothing");
        }
    }

    /// The full policy a fresh view or a profile default gets from this
    /// patch: said fields copy over, omitted fields keep `NetPolicy`'s
    /// defaults. Generic over the fields, so it cannot drift.
    pub fn effective(self: NetPolicyPatch) NetPolicy {
        var out = NetPolicy{};
        inline for (std.meta.fields(NetPolicy)) |f| {
            if (@field(self, f.name)) |v| @field(out, f.name) = v;
        }
        return out;
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

/// Serializes one ENGINE's [probe -> spawn -> bind -> greet] window
/// across sibling MCP clients, via an flock on its own lock file
/// (`<dir>/web.lock` direct, `<dir>/web-<slug>.lock` per route).
/// Best-effort by design: failure to take it reverts to the old racy
/// behavior (worst case: a doubled spawn), never to a refusal.
const SpawnLock = struct {
    fd: c_int = -1,

    fn take(path: [:0]const u8) SpawnLock {
        const fd = c.open(path.ptr, c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o600));
        if (fd < 0) return .{};
        const deadline = clock.nowMs() + SPAWN_LOCK_WAIT_MS;
        while (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) {
            if (clock.nowMs() >= deadline) {
                _ = c.close(fd);
                return .{};
            }
            _ = c.usleep(50_000);
        }
        return .{ .fd = fd };
    }

    fn release(self: *SpawnLock) void {
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
    }
};

/// View ids are minted PROCESS-WIDE, not per engine: one route is one
/// engine, and the handle the `web_*` tools hand back must name exactly
/// one view across all of them. (`webface.zig` mints its ids the same
/// way, for the same reason.)
var g_next_view: u32 = 1;

fn nextViewId() u32 {
    const id = g_next_view;
    g_next_view +%= 1;
    if (g_next_view == 0) g_next_view = 1;
    return id;
}

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
    /// This engine's network route: `.direct` is the plain unproxied
    /// helper whose paths are the historical ones. The two string halves
    /// are owned copies, because a `webroute.Spec` borrows them and this
    /// struct is returned by value from `init`.
    route_kind: webroute.Kind = .direct,
    route_host: []u8 = &.{},
    route_endpoint: []u8 = &.{},
    session: ?WebSession = null,
    /// Latched when a helper failed to START with the session
    /// environment: later spawns go plain headless instead of paying a
    /// doomed session + spawn per tool call.
    session_blocked: bool = false,
    state: State = .idle,
    owner: Owner = .none,
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
    /// The helper serves several concurrent clients (Phase 1). Gates
    /// teardown: a multi-client helper that has not exited by the
    /// grace deadline is serving someone else (or mid-flush) and must
    /// be ABANDONED, never signalled.
    cap_multi_client: bool = false,
    /// The helper presents its views as toplevels on the web session
    /// (`presenter` in hello_ack). Reported, never inferred: a helper
    /// in session mode whose presenter failed to arm still says no.
    cap_presenter: bool = false,
    /// The helper lets a second client OBSERVE this one's views
    /// (`observe`): what the GUI's Watch / Take control on this
    /// assistant's browser rides on. Reported, never inferred.
    cap_observe: bool = false,
    /// The helper can really open popups (`popup-open`). Headless
    /// clients ALLOW them: an agent driving a sign-in flow needs the
    /// window the provider posts its result back through, and there is
    /// no user here for a popup to annoy.
    cap_popup_open: bool = false,
    /// The helper reports downloads (`ev_download_offer` and the rest
    /// of the 0x78 block). Without it a download this client cannot
    /// answer is held helper-side and nothing lands anywhere.
    cap_downloads: bool = false,
    /// The helper accepts `download_start`: a url can be fetched
    /// through the view's own browser, with its cookies and session.
    cap_download_start: bool = false,
    /// Downloads this engine has seen, page-initiated ones included.
    /// Bounded by `DOWNLOAD_CAP`, drop-oldest-finished.
    downloads: std.ArrayList(Download) = .empty,
    next_download_req: u32 = 1,
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
    /// The LOCAL fallback: `remote` (the broker-owned store) is tried
    /// first for named instances and wins when the daemon serves it.
    store: ?webprofiles.Store = null,
    /// Broker-owned profile store, the normal path for a NAMED
    /// instance: the daemon holds the flock and allocates ids, so N
    /// concurrent clients of one instance all get working profiles.
    remote: ?webremote.Remote = null,
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

    /// `route` selects the instance this engine IS; an invalid spec is
    /// refused rather than downgraded, because a route whose proxy is
    /// missing configures no proxy at all (see `webroute.Spec.valid`).
    pub fn init(
        gpa: std.mem.Allocator,
        dir: []const u8,
        instance: ?[]const u8,
        mux_sock: ?[]const u8,
        route: webroute.Spec,
    ) !Engine {
        if (!route.valid()) return error.InvalidRoute;
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
        errdefer if (owned_sock) |sck| gpa.free(sck);
        const owned_host = try gpa.dupe(u8, route.host);
        errdefer gpa.free(owned_host);
        const owned_endpoint = try gpa.dupe(u8, route.endpoint);
        return .{
            .gpa = gpa,
            .dir = owned_dir,
            .instance = owned_instance,
            .client_name = name,
            .mux_sock = owned_sock,
            .route_kind = route.kind,
            .route_host = owned_host,
            .route_endpoint = owned_endpoint,
        };
    }

    /// This engine's route as the shared value type.
    pub fn routeSpec(self: *const Engine) webroute.Spec {
        return .{ .kind = self.route_kind, .host = self.route_host, .endpoint = self.route_endpoint };
    }

    /// The route's user-facing text (`direct` | `tor` | `via:<host>` |
    /// `on:<host>`), rendered into `buf`.
    pub fn routeText(self: *const Engine, buf: []u8) []const u8 {
        return self.routeSpec().format(buf) orelse "direct";
    }

    /// `<dir>/web<ext>` for the direct route, `<dir>/web-<slug><ext>`
    /// for any other. The direct spelling is the historical one byte for
    /// byte: a changed socket or store path strands the profiles behind
    /// it (the rule `webface.clientForRoute` follows).
    fn routePathZ(self: *const Engine, buf: []u8, ext: []const u8) ?[:0]u8 {
        if (self.route_kind == .direct)
            return std.fmt.bufPrintZ(buf, "{s}/web{s}", .{ self.dir, ext }) catch null;
        var slug_buf: [64]u8 = undefined;
        const slug = self.routeSpec().slug(&slug_buf) orelse return null;
        return std.fmt.bufPrintZ(buf, "{s}/web-{s}{s}", .{ self.dir, slug, ext }) catch null;
    }

    /// Kill and reap the helper; safe to call from a signal-driven
    /// teardown path (the helper also exits on its own when this
    /// process's socket closes).
    pub fn deinit(self: *Engine) void {
        self.dropConnection();
        if (self.pid > 0 and self.cap_multi_client and self.remote != null) {
            // Broker-owned store + multi-client helper: the helper
            // exits (and flushes jars via `cef_shutdown`) with its LAST
            // client on its own, whether or not this process waits —
            // and while ANOTHER client is connected it must not be
            // waited for, let alone signalled. Nothing here depends on
            // the exit either: the flock is the daemon's, so no
            // successor can take the CEF root early. One immediate reap
            // attempt for the already-exited case; otherwise init reaps
            // it after this process is gone.
            var status: c_int = 0;
            if (c.waitpid(self.pid, &status, c.WNOHANG) != self.pid) {
                const note = "sketerm mcp: leaving the multi-client browser helper to exit with its last client\n";
                _ = c.write(2, note, note.len);
            }
            self.pid = -1;
        }
        if (self.pid > 0) {
            var status: c_int = 0;
            // Let the helper exit ON ITS OWN first. The closed socket is
            // its exit signal, and the clean path it then runs (close
            // every browser, `cef_shutdown`) is what FLUSHES a profile's
            // cookies to disk. Signalling here instead cost every named
            // profile the session that had just been written into it —
            // the jar was durable and always came back empty. (With a
            // LOCAL flock this wait is also the release-order guard: the
            // flock must not free while CEF still holds the root, or the
            // next client opens a colliding, silently-empty store.)
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
        // the session's socket goes away under it. EXCEPT under the
        // shared (broker-store, multi-client) shape, where the helper
        // may outlive this client to serve its siblings: destroying the
        // session would yank the compositor from under THEIR engine —
        // and the destroy round trip blocks on the live client anyway.
        // Dropping our connection without destroy hands the session to
        // the daemon's own liveness rule: it reaps once no Wayland
        // client (i.e. the helper) remains.
        self.teardownSession(!(self.cap_multi_client and self.remote != null));
        if (self.mux_sock) |sck| {
            self.gpa.free(sck);
            self.mux_sock = null;
        }
        self.clearViews();
        self.views.deinit(self.gpa);
        self.clearDownloads();
        self.downloads.deinit(self.gpa);
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
        if (self.remote) |*r| {
            r.deinit();
            self.remote = null;
        }
        // The flock goes only after the helper is reaped, or a
        // successor could take the root while CEF still holds it open.
        if (self.store) |*s| {
            s.deinit();
            self.store = null;
        }
        self.clearStoreReason();
        if (self.instance) |n| self.gpa.free(n);
        self.instance = null;
        self.gpa.free(self.route_host);
        self.route_host = &.{};
        self.gpa.free(self.route_endpoint);
        self.route_endpoint = &.{};
        self.gpa.free(self.dir);
        self.gpa.free(self.client_name);
        self.state = .idle;
        self.owner = .none;
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
        // A ROUTED engine keeps a store of its own, keyed by the route's
        // slug: the root IS its `--cache-dir`, and no other CEF process
        // may share that. The broker's store is the instance's DIRECT
        // root, so a routed engine never takes the broker lane either.
        if (self.route_kind != .direct) {
            var key_buf: [96]u8 = undefined;
            var slug_buf: [64]u8 = undefined;
            const slug = self.routeSpec().slug(&slug_buf) orelse {
                self.setStoreReason("this route has no stable storage key, so it has no profile store", false);
                return;
            };
            // Slug FIRST: `webprofiles` truncates a long key, and two
            // routes sharing a store root would share their cookies.
            const key = std.fmt.bufPrint(&key_buf, "{s}-{s}", .{ slug, self.instance orelse "anon" }) catch slug;
            self.openLocalStore(key);
            return;
        }
        // Broker-owned store first, NAMED instances only: the named
        // instance's daemon is durable, so it is the one process that
        // can hold the flock across every client's lifetime — which is
        // what lets a SECOND concurrent client keep working profiles.
        // An anonymous instance's daemon is private and ephemeral
        // (idle-exit), so parking the shared "anon" root's flock there
        // would only DELAY the next anonymous client; anon keeps the
        // local flock exactly as before.
        if (self.instance != null and self.mux_sock != null) {
            var reason_buf: [192]u8 = undefined;
            var reason_len: usize = 0;
            if (webremote.Remote.open(self.gpa, self.mux_sock.?, self.instance.?, &reason_buf, &reason_len)) |rem| {
                self.remote = rem;
                self.clearStoreReason();
                return;
            } else |err| switch (err) {
                // No capability (old daemon) or no daemon answer: the
                // local flock below IS the old behavior, refusal
                // sentences included. A daemon-side refusal also falls
                // through — the local attempt reproduces the same
                // condition (Locked/Io) with the richer local message.
                error.Unsupported, error.Refused, error.Io, error.OutOfMemory => {},
            }
        }
        self.openLocalStore(self.instance);
    }

    /// The local (flock'd) profile store under `key`'s root. Failure is
    /// not fatal: the engine keeps a volatile cache dir and every
    /// profile request is refused with `store_reason`.
    fn openLocalStore(self: *Engine, key: ?[]const u8) void {
        var holder: c.pid_t = 0;
        self.store = webprofiles.Store.open(self.gpa, key, &holder) catch |err| {
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

    /// A profile store is usable, broker-owned or local.
    fn hasStore(self: *Engine) bool {
        return self.remote != null or self.store != null;
    }

    /// The store root (the helper's `--cache-dir`); null without one.
    fn storeRoot(self: *Engine) ?[]const u8 {
        if (self.remote) |*r| return r.root;
        if (self.store) |*s| return s.root;
        return null;
    }

    /// The persisted id `name` must be opened with, whichever side
    /// allocates it.
    fn storeEnsure(self: *Engine, name: []const u8) webprofiles.Error!u32 {
        if (self.remote) |*r| return r.ensure(name);
        if (self.store) |*s| return s.ensure(name);
        return error.Io;
    }

    fn storeTouch(self: *Engine, name: []const u8) void {
        if (self.remote) |*r| return r.touch(name);
        if (self.store) |*s| s.touch(name, clock.nowMs());
    }

    /// Name of the live watchable Wayland session the helper was
    /// started against; null in plain headless mode.
    pub fn sessionName(self: *const Engine) ?[]const u8 {
        if (self.session) |*s| return s.created.name;
        return null;
    }

    /// Whether an attached viewer sees PIXELS: the helper is a session
    /// client AND advertised the presenter in its handshake.
    pub fn presenterActive(self: *const Engine) bool {
        return self.session != null and self.state == .ready and self.cap_presenter;
    }

    /// Whether a GUI can watch this engine's pages as browser pages:
    /// the live helper advertised `observe`.
    pub fn observeActive(self: *const Engine) bool {
        return self.state == .ready and self.cap_observe;
    }

    /// The helper socket a second client connects to, once the helper
    /// is serving; null before that.
    pub fn helperSocketPath(self: *const Engine, buf: []u8) ?[]const u8 {
        if (self.state != .ready) return null;
        return self.routePathZ(buf, ".sock");
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
        const p = self.routePathZ(&path_z, ".json") orelse return;
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
        const p = self.routePathZ(&path_z, ".json") orelse return;
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
        self.cap_multi_client = false;
        self.cap_downloads = false;
        self.cap_download_start = false;
        // A download in flight died with the helper. Failing it here is
        // what turns a lost helper into an ANSWER for whoever is
        // waiting on the file, instead of a wait that runs out.
        self.failDownloads(LOST_MSG);
        self.removePresence();
        self.state = .unavailable;
        self.owner = .none;
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

        var dir_z: [4096:0]u8 = undefined;
        const dz = std.fmt.bufPrintZ(&dir_z, "{s}", .{self.dir}) catch return self.failStart("helper directory path too long");
        _ = c.mkdir(dz.ptr, 0o700);
        var sock_z: [108:0]u8 = undefined;
        const sock = self.routePathZ(&sock_z, ".sock") orelse
            return self.failStart("helper socket path exceeds the unix socket limit (use a shorter runtime dir)");

        // Serialize [probe -> spawn -> bind] against SIBLING clients of
        // this instance dir: without it, two clients finding no helper
        // both spawn, and the second's unlink() yanks the socket from
        // under the first's bind. Best-effort — an unobtainable lock
        // degrades to the old racy behavior, never to a refusal.
        var lock_z: [4096:0]u8 = undefined;
        var spawn_lock = if (self.routePathZ(&lock_z, ".lock")) |lp| SpawnLock.take(lp) else SpawnLock{};
        defer spawn_lock.release();

        // Adopt a live helper before spawning one: with the broker
        // owning the profile store, a SECOND client of a named
        // instance is the expected shape, and the multi-client helper
        // serves each on its own connection. A stale/single-client
        // helper accepts but never answers the handshake; the ack
        // deadline turns that into a described failure, after which
        // one spawn attempt gets its own try below.
        if (self.tryConnect(sock)) |fd| {
            if (self.adopt(fd, .adopted)) return true;
            if (self.state == .unavailable and self.retryable) self.state = .idle;
        }

        // Broker-owned engine (Phase 3): with a broker-side store, ask
        // THE BROKER to spawn the engine (linger lifecycle, one owner,
        // presence file included) and adopt it — the client never
        // spawns. Any refusal falls through to the local spawn below,
        // which is exactly the Phase 2 shape. What the broker lane
        // deliberately does NOT provide is the watchable Wayland
        // session (the engine must outlive every client, and the
        // session env was minted per client); SKETERM_WEB_BROKER_ENGINE=0
        // is the escape hatch back to the client-spawn lane, session
        // included — the SKETERM_NO_BROKER precedent.
        // A routed engine never takes this lane: the broker's engine is
        // the instance's DIRECT one (its own socket, no `--proxy`), so
        // adopting it for a route would browse direct under a route.
        if (self.remote != null and self.route_kind == .direct and brokerEngineWanted()) {
            if (self.brokerEngine(sock)) return true;
            if (self.state == .unavailable and self.retryable) self.state = .idle;
        }

        var bin_buf: [4096:0]u8 = undefined;
        const bin = findbin.find(&bin_buf) orelse {
            self.state = .unavailable;
            self.reason = MISSING_MSG;
            self.retryable = false;
            return false;
        };
        // The helper's --cache-dir IS its `root_cache_path`, and CEF
        // demands every persistent context's jar be a child of it — so
        // the durable profile store root has to BE that dir. Without a
        // store the old volatile dir stays, and profiles stay refused.
        // A routed engine has a store root of its own (see `openStore`),
        // so this is a per-instance path either way: two CEF processes
        // sharing a root_cache_path is measured-fatal.
        var cache_z: [4096:0]u8 = undefined;
        if (self.storeRoot()) |root| {
            _ = std.fmt.bufPrintZ(&cache_z, "{s}", .{root}) catch return self.failStart("helper cache path too long");
        } else if (self.routePathZ(&cache_z, "-cache") == null) {
            return self.failStart("helper cache path too long");
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

    fn brokerEngineWanted() bool {
        const v = c.getenv("SKETERM_WEB_BROKER_ENGINE") orelse return true;
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
        return !(std.mem.eql(u8, s, "0") or std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "no"));
    }

    /// Ask the broker for its engine (web_op engine_open) and adopt it.
    /// The broker replies before the engine binds — CEF startup is
    /// seconds and must not block the daemon's loop — so the connect
    /// wait lives HERE, without a waitpid (the pid is the broker's
    /// child, not ours).
    fn brokerEngine(self: *Engine, sock: [:0]const u8) bool {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const info = self.remote.?.engineOpen(arena_state.allocator()) catch return false;
        // The broker's engine listens where every sibling expects it
        // (this instance dir); a different path would mean a confused
        // daemon and adopting it would bind views to the wrong root.
        if (!std.mem.eql(u8, info.sock, sock)) return false;
        const deadline = clock.nowMs() + SPAWN_WAIT_MS;
        const fd: c_int = while (true) {
            if (self.tryConnect(sock)) |fd| break fd;
            if (clock.nowMs() >= deadline)
                return self.failStart("the broker's browser engine did not bind its socket in time");
            _ = c.usleep(100_000);
        };
        return self.adopt(fd, .broker);
    }

    /// Whether the NEXT engine start would go through the broker lane
    /// (daemon advertises `web_engine`, broker store open, env hatch
    /// not set). Answers `capabilities` before any view exists; once an
    /// engine is up, `owner` is the fact.
    pub fn brokerLaneAvailable(self: *Engine) bool {
        if (self.route_kind != .direct) return false;
        if (!brokerEngineWanted()) return false;
        self.openStore();
        if (self.remote) |*r| return r.engineSupported();
        return false;
    }

    /// One spawn + connect + handshake attempt. On success the engine
    /// is `.ready` with the presence file written.
    fn startHelper(self: *Engine, bin: [*:0]const u8, sock: [:0]const u8, sock_z: *[108:0]u8, cache_z: *[4096:0]u8) bool {
        // A stale socket from a crashed helper would make the connect
        // succeed against nothing.
        _ = c.unlink(sock.ptr);
        const env = self.sessionEnv();

        // The route's proxy, prepared BEFORE the fork (nothing may
        // allocate between fork and exec). `.mux` names none here: its
        // bridge port is not known until the bridge binds, so an
        // unproxiable route must never reach this function.
        var proxy_z: [512:0]u8 = undefined;
        var proxy_buf: [512]u8 = undefined;
        const proxy: ?[*:0]const u8 = if (self.routeSpec().proxyUrl(&proxy_buf)) |url|
            (std.fmt.bufPrintZ(&proxy_z, "{s}", .{url}) catch
                return self.failStart("the route's proxy url is too long")).ptr
        else
            null;

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
                // Arm the presenter: THIS helper is a client of a hub
                // nobody else renders into, so its toplevels are the
                // watch-along surface and not a stray desktop window.
                _ = c.setenv(proto.CAP_PRESENTER_ENV, "1", 1);
                _ = c.unsetenv("WAYLAND_SOCKET");
                _ = c.unsetenv("DISPLAY");
                _ = c.unsetenv("XAUTHORITY");
            }
            var argv: [8:null]?[*:0]const u8 = .{ bin, "--socket", sock_z, "--cache-dir", cache_z, null, null, null };
            if (proxy) |p| {
                argv[5] = "--proxy";
                argv[6] = p;
            }
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
        return self.handshake(fd, .self_spawned);
    }

    /// Hello/ack on an established helper connection, shared by the
    /// spawn path and adoption. `spawned` scopes the child-only work:
    /// killing it on a failed handshake, and writing the presence file
    /// (only the client that owns the pid can record it truthfully).
    fn handshake(self: *Engine, fd: c_int, owner: Owner) bool {
        const spawned = owner == .self_spawned;
        self.fd = fd;
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        self.state = .ready;
        self.owner = owner;

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
                if (spawned) self.killChild();
                self.lost();
                self.reason = "the browser helper never answered the protocol handshake";
                return false;
            }
            self.pumpOnce(50);
        }
        if (self.state == .ready) {
            self.helper_gen +%= 1;
            if (self.helper_gen == 0) self.helper_gen = 1;
            if (spawned) self.writePresence();
        }
        return self.state == .ready;
    }

    /// Join a helper another client of this instance spawned. No child
    /// pid: teardown just closes the socket, and the helper exits with
    /// its LAST client (Phase 1's contract).
    fn adopt(self: *Engine, fd: c_int, owner: Owner) bool {
        return self.handshake(fd, owner);
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
        const new_id = nextViewId();
        var pol_serial: u32 = 0;
        if (policy) |p| {
            pol_serial = self.next_policy_serial;
            self.next_policy_serial += 1;
            self.send(policyFrame(new_id, pol_serial, p)) catch return error.Unavailable;
            if (p.block_ads) |on| {
                self.send(proto.InterceptSet{ .view = new_id, .enabled = if (on) 1 else 0 }) catch return error.Unavailable;
            }
        }

        const v = try self.gpa.create(View);
        // Covers both halves: before the append it just destroys the
        // view, after it also unlinks it from `views` (a bare destroy
        // there would leave a dangling pointer in the list).
        errdefer self.abandonView(v);
        const owned_profile: ?[]u8 = if (profile_name.len > 0) try self.gpa.dupe(u8, profile_name) else null;
        v.* = .{
            .id = new_id,
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
    /// Adopt a popup the helper created, so `web_tabs` lists it and
    /// every `web_*` tool can address it. Nothing is navigated: the
    /// engine already loaded it, and re-navigating would discard the
    /// opener relationship the popup exists for.
    fn adoptPopupView(self: *Engine, ev: proto.EvPagePopup) !void {
        if (self.findView(ev.popup_view) != null) return;
        const opener = self.findView(ev.owner_view);
        const v = try self.gpa.create(View);
        errdefer self.gpa.destroy(v);
        v.* = .{
            .id = ev.popup_view,
            .w = if (ev.w == 0) 1024 else ev.w,
            .h = if (ev.h == 0) 768 else ev.h,
            // The engine gives a popup its OPENER's request context, so
            // the record must say so or a later lookup would disagree
            // with where the cookies actually are.
            .context = if (opener) |o| o.context else 0,
        };
        errdefer v.deinit(self.gpa);
        if (opener) |o| {
            if (o.profile) |pf| v.profile = try self.gpa.dupe(u8, pf);
        }
        if (ev.url.len > 0) v.url = try self.gpa.dupe(u8, ev.url);
        try self.views.append(self.gpa, v);
    }

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
                if (!self.hasStore()) return error.StoreUnavailable;
                const id = self.storeEnsure(name) catch |err| return switch (err) {
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
                    self.storeTouch(name);
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
                self.storeTouch(name);
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
        if (!self.hasStore()) return false;
        if (self.state == .ready) return self.contextsSupported();
        return true;
    }

    /// The sentence explaining a false `profilesAvailable`.
    pub fn profileUnavailableReason(self: *Engine) []const u8 {
        self.openStore();
        if (!self.hasStore())
            return if (self.store_reason.len > 0) self.store_reason else "the browser profile store is unavailable";
        if (self.state == .ready and !self.contextsSupported())
            return "this browser helper does not advertise isolated identity contexts (capabilities 'contexts' + 'contexts-fail-closed'); named profiles are refused rather than silently sharing the default cookie jar";
        return "";
    }

    /// Where the profiles' cookies and caches live; null when there is
    /// no store.
    pub fn profileStorePath(self: *Engine) ?[]const u8 {
        self.openStore();
        return self.storeRoot();
    }

    /// Every known profile, store ∪ live. Never spawns the helper.
    pub fn profileList(self: *Engine, arena: std.mem.Allocator) ![]ProfileInfo {
        self.openStore();
        var out: std.ArrayList(ProfileInfo) = .empty;
        if (self.remote) |*r| {
            const rows = r.entries(arena) catch return out.items;
            for (rows) |e| try self.appendProfileInfo(&out, arena, e.name, e.id, e.created_ms, e.last_used_ms);
            return out.items;
        }
        const store = if (self.store) |*s| s else return out.items;
        for (store.list()) |e| {
            try self.appendProfileInfo(&out, arena, e.name, e.id, e.created_ms, e.last_used_ms);
        }
        return out.items;
    }

    /// One store row merged with this CLIENT's live view/publish state.
    /// Another client's views in the same profile are not visible here
    /// — the row still lists, only `views`/`live` are local truth.
    fn appendProfileInfo(
        self: *Engine,
        out: *std.ArrayList(ProfileInfo),
        arena: std.mem.Allocator,
        name: []const u8,
        id: u32,
        created_ms: i64,
        last_used_ms: i64,
    ) !void {
        var views: u32 = 0;
        var live = false;
        for (self.live.items) |ctx| {
            if (ctx.ephemeral or !std.mem.eql(u8, ctx.name, name)) continue;
            views = ctx.views;
            live = ctx.published_gen == self.helper_gen and self.state == .ready;
        }
        try out.append(arena, .{
            .name = try arena.dupe(u8, name),
            .id = id,
            .views = views,
            .created_ms = created_ms,
            .last_used_ms = last_used_ms,
            .live = live,
        });
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
        if (!self.hasStore()) return error.StoreUnavailable;
        // Local truth only: another client's views in this profile are
        // invisible here, so a cross-client reset is best-effort — the
        // engine keeps a destroyed context alive for existing browsers
        // (contextDestroy's documented semantics) and CEF recreates a
        // removed jar directory on demand.
        if (self.profileViewCount(name) > 0) return error.InUse;
        if (self.remote) |*r| {
            self.dropLiveCtx(name);
            const res = r.retire(name) catch |err| return switch (err) {
                error.BadName => error.InvalidName,
                error.Io, error.OutOfMemory => error.StoreIo,
            };
            if (!res.removed) return error.NoProfile;
            return res.id;
        }
        const store = &self.store.?;
        const entry = store.find(name) orelse return error.NoProfile;
        self.dropLiveCtx(name);
        _ = store.retire(name) catch |err| return switch (err) {
            error.BadName => error.InvalidName,
            error.Io, error.OutOfMemory => error.StoreIo,
        };
        return entry.id;
    }

    /// Unpublish this client's live context for `name`, if any.
    fn dropLiveCtx(self: *Engine, name: []const u8) void {
        for (self.live.items, 0..) |ctx, i| {
            if (ctx.ephemeral or !std.mem.eql(u8, ctx.name, name)) continue;
            if (self.state == .ready) self.send(proto.ContextDestroy{ .id = ctx.id }) catch {};
            const dead = self.live.orderedRemove(i);
            if (dead.name.len > 0) self.gpa.free(dead.name);
            return;
        }
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

        try self.tightenHosts(old.allow_top, incoming.allow_top, &next.allow_top, &report, "allow_hosts");
        try self.tightenHosts(old.allow_sub, incoming.allow_sub, &next.allow_sub, &report, "allow_subresource_hosts");
        if (incoming.block_types) |want| {
            if (want & ~old.block_types != 0) {
                next.block_types = old.block_types | want;
                report.tight("block_types");
            }
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

    /// An omitted host list is untouched; a present one INTERSECTS (an
    /// explicit empty list narrows to no hosts), and any host it names
    /// beyond the old list is a loosening named under `name`.
    fn tightenHosts(self: *Engine, old: []const []const u8, incoming: ?[]const []const u8, out: *[]const []const u8, report: *TightenReport, name: []const u8) !void {
        const want = incoming orelse return;
        var extra = false;
        for (want) |h| {
            if (!hostListed(old, h)) extra = true;
        }
        if (extra) report.ign(name);
        const kept = try intersectHosts(self.gpa, old, want);
        if (kept.len < old.len) {
            freeHostList(self.gpa, out.*);
            out.* = kept;
            report.tight(name);
        } else {
            freeHostList(self.gpa, kept);
        }
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

    const hostListed = strz.contains;

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

    /// The one rule for when the records stop describing the view.
    fn loadStarted(self: *Engine, v: *View, url: []const u8) void {
        navfault.loadStarted(self.gpa, &v.cert, &v.load_error, url);
    }

    /// Let ONE certificate through on this view, by fingerprint. Set
    /// right after `openViewIn` and before the first pump, so the hold
    /// the navigation raises is answered against it; it stays for the
    /// view's life, so a later navigation to the same device is not a
    /// second interstitial.
    pub fn setAcceptCert(self: *Engine, id: u32, fingerprint: []const u8) !void {
        const v = self.findView(id) orelse return error.NoView;
        if (!navfault.validFingerprint(fingerprint)) return error.InvalidFingerprint;
        const lowered = try std.ascii.allocLowerString(self.gpa, fingerprint);
        if (v.accept_fingerprint) |old| self.gpa.free(old);
        v.accept_fingerprint = lowered;
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

    /// Mirror one `ev_console` line into the view's bounded ring.
    fn pushConsole(self: *Engine, v: *View, level: u8, msg: []const u8) void {
        const text = self.gpa.dupe(u8, msg[0..@min(msg.len, CONSOLE_LINE_MAX)]) catch return;
        v.console.append(self.gpa, .{ .id = v.console_next_id, .level = level, .text = text }) catch {
            self.gpa.free(text);
            return;
        };
        v.console_next_id +%= 1;
        if (v.console.items.len > CONSOLE_CAP) {
            const old = v.console.orderedRemove(0);
            self.gpa.free(old.text);
            v.console_dropped += 1;
        }
    }

    /// The mirrored console lines with id > `since` (0 = everything
    /// still held). Slices borrow the ring: consume before pumping.
    pub fn consoleTail(self: *Engine, id: u32, since: u32) !struct { lines: []const ConsoleLine, dropped: u32, next: u32 } {
        const v = self.findView(id) orelse return error.NoView;
        var start: usize = 0;
        for (v.console.items, 0..) |line, i| {
            if (line.id > since) break;
            start = i + 1;
        }
        return .{ .lines = v.console.items[start..], .dropped = v.console_dropped, .next = v.console_next_id };
    }

    /// Focus + a trusted key chord (down with text, then up) through
    /// the ordinary input path - the same frames a GUI keystroke rides.
    pub fn sendKey(self: *Engine, id: u32, keysym: u32, mods: u32, text: []const u8) !void {
        if (!self.ensure()) return error.Unavailable;
        if (self.findView(id) == null) return error.NoView;
        self.awaitFirstPaint(id, 5_000);
        self.send(proto.InputKey{
            .view = id,
            .kind = @intFromEnum(proto.KeyKind.down),
            .keyval = keysym,
            .keycode = 0,
            .mods = mods,
            .text = text,
        }) catch return error.Unavailable;
        self.send(proto.InputKey{
            .view = id,
            .kind = @intFromEnum(proto.KeyKind.up),
            .keyval = keysym,
            .keycode = 0,
            .mods = mods,
            .text = "",
        }) catch return error.Unavailable;
    }

    /// Tell the engine the view has keyboard focus; keys are dropped
    /// into the void without it (a GUI sends this on focus-in).
    pub fn focusView(self: *Engine, id: u32) !void {
        if (!self.ensure()) return error.Unavailable;
        if (self.findView(id) == null) return error.NoView;
        self.send(proto.InputFocus{ .view = id, .focused = 1 }) catch return error.Unavailable;
    }

    /// Resize the viewport in place; node geometry and media queries
    /// re-evaluate, ids survive (same document, same tree).
    pub fn resize(self: *Engine, id: u32, w: u16, h: u16) !void {
        if (!self.ensure()) return error.Unavailable;
        const v = self.findView(id) orelse return error.NoView;
        self.send(proto.ViewResize{ .view = id, .w = w, .h = h, .scale_x1000 = 1000 }) catch return error.Unavailable;
        v.w = w;
        v.h = h;
    }

    /// The full text of the last eval result on `id`, if any.
    pub fn lastEval(self: *Engine, id: u32) ?[]const u8 {
        const v = self.findView(id) orelse return null;
        return v.last_eval;
    }

    // ---- downloads ---------------------------------------------------
    //
    // The helper HOLDS every download's target decision until a client
    // answers it. This client answers: an asked-for download
    // (`startDownload`) into the caller's path, a page-initiated one
    // into the user's download directory. Ignoring the frames — which
    // is what this driver did before — means the engine holds the
    // decision, the page's `a.click()` reports success and no file is
    // ever written anywhere, with no error on any side.

    /// Downloads remembered per engine. Finished ones are dropped
    /// oldest-first past this; a running one is never dropped.
    pub const DOWNLOAD_CAP: usize = 64;

    fn clearDownloads(self: *Engine) void {
        for (self.downloads.items) |*d| d.deinit(self.gpa);
        self.downloads.clearRetainingCapacity();
    }

    fn failDownloads(self: *Engine, reason: []const u8) void {
        for (self.downloads.items) |*d| {
            if (d.terminal()) continue;
            d.failed = true;
            d.fail_reason = reason;
        }
    }

    /// The download record for a client request id.
    pub fn download(self: *Engine, req: u32) ?*Download {
        for (self.downloads.items) |*d| {
            if (d.req == req) return d;
        }
        return null;
    }

    /// Every download this engine knows about, oldest first.
    pub fn downloadList(self: *Engine) []const Download {
        return self.downloads.items;
    }

    fn downloadById(self: *Engine, view: u32, id: u32) ?*Download {
        for (self.downloads.items) |*d| {
            if (d.id == id and d.view == view) return d;
        }
        return null;
    }

    /// Room for one more record: drop the oldest FINISHED one.
    fn trimDownloads(self: *Engine) void {
        while (self.downloads.items.len >= DOWNLOAD_CAP) {
            var idx: ?usize = null;
            for (self.downloads.items, 0..) |*d, i| {
                if (d.terminal()) {
                    idx = i;
                    break;
                }
            }
            const at = idx orelse return;
            var gone = self.downloads.orderedRemove(at);
            gone.deinit(self.gpa);
        }
    }

    fn nextDownloadReq(self: *Engine) u32 {
        const r = self.next_download_req;
        self.next_download_req +%= 1;
        if (self.next_download_req == 0) self.next_download_req = 1;
        return r;
    }

    /// Ask `view`'s browser to download `url` ITSELF, so the request
    /// carries that browser's cookies, session and route — the whole
    /// point of downloading through a signed-in page rather than
    /// re-fetching the url from outside it.
    ///
    /// `path` is where the bytes land (absolute); null means the user's
    /// download directory under the engine-suggested name. Returns the
    /// request id to poll with `download`.
    pub fn startDownload(self: *Engine, view_id: u32, url: []const u8, path: ?[]const u8) DownloadError!u32 {
        if (!self.ensure()) return error.Unavailable;
        if (!self.cap_downloads or !self.cap_download_start) return error.Unsupported;
        if (self.findView(view_id) == null) return error.NoView;
        if (path) |p| {
            if (p.len == 0 or p[0] != '/') return error.BadPath;
        }
        self.trimDownloads();
        const req = self.nextDownloadReq();
        const url_owned = try self.gpa.dupe(u8, url);
        errdefer self.gpa.free(url_owned);
        const path_owned: []u8 = if (path) |p| try self.gpa.dupe(u8, p) else &.{};
        errdefer if (path_owned.len != 0) self.gpa.free(path_owned);
        try self.downloads.append(self.gpa, .{
            .req = req,
            .view = view_id,
            .url = url_owned,
            .path = path_owned,
            .started_ms = clock.nowMs(),
        });
        self.send(proto.DownloadStart{ .view = view_id, .req = req, .url = url }) catch {
            // Drop the record only; the two errdefers above own those
            // slices until this function returns successfully, and
            // freeing them here as well would be a double free.
            _ = self.downloads.pop();
            return error.Unavailable;
        };
        return req;
    }

    /// Cancel a running download; a finished one is left alone.
    pub fn cancelDownload(self: *Engine, req: u32) void {
        const d = self.download(req) orelse return;
        if (d.terminal()) return;
        if (d.id != 0) self.send(proto.DownloadCancel{ .view = d.view, .id = d.id }) catch {};
        d.failed = true;
        d.fail_reason = "canceled";
    }

    /// Where a download with no caller-chosen path lands. The user's
    /// XDG download directory (`fsserve.downloadDir`), created if it is
    /// missing.
    fn downloadDirZ(buf: []u8) ?[]const u8 {
        const home_c = c.getenv("HOME") orelse return null;
        const home = std.mem.span(@as([*:0]const u8, @ptrCast(home_c)));
        if (home.len == 0) return null;
        var cfg_buf: [4096]u8 = undefined;
        const config_home: []const u8 = blk: {
            if (c.getenv("XDG_CONFIG_HOME")) |x| {
                const s = std.mem.span(@as([*:0]const u8, @ptrCast(x)));
                if (s.len != 0) break :blk s;
            }
            break :blk std.fmt.bufPrint(&cfg_buf, "{s}/.config", .{home}) catch return null;
        };
        const dir = fsserve.downloadDir(home, config_home, buf);
        if (dir.len == 0) return null;
        var z: [4096:0]u8 = undefined;
        const zp = pathz.pathZ(&z, dir) catch return null;
        _ = c.mkdir(zp, 0o755);
        return dir;
    }

    /// `<dir>/<name>`, with " (n)" before the extension while the plain
    /// name is taken — a download must never silently overwrite a file
    /// the user already has.
    fn uniqueDownloadPath(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
        const dot = blk: {
            const at = std.mem.lastIndexOfScalar(u8, name, '.') orelse break :blk name.len;
            break :blk if (at == 0) name.len else at;
        };
        var n: u32 = 0;
        while (n < 1000) : (n += 1) {
            const candidate = if (n == 0)
                std.fmt.bufPrint(buf, "{s}/{s}", .{ dir, name }) catch return null
            else
                std.fmt.bufPrint(buf, "{s}/{s} ({d}){s}", .{ dir, name[0..dot], n, name[dot..] }) catch return null;
            var z: [4096:0]u8 = undefined;
            const zp = pathz.pathZ(&z, candidate) catch return null;
            if (c.access(zp, c.F_OK) != 0) return candidate;
        }
        return null;
    }

    /// A suggested file name reduced to a leaf that is safe to join
    /// onto a directory: no separators, no `..`, never empty.
    fn safeLeaf(name: []const u8) []const u8 {
        const leaf = std.fs.path.basename(name);
        if (leaf.len == 0 or std.mem.eql(u8, leaf, ".") or std.mem.eql(u8, leaf, "..")) return "download";
        return leaf[0..@min(leaf.len, 200)];
    }

    fn setDownloadStr(self: *Engine, slot: *[]u8, text: []const u8) void {
        const owned = self.gpa.dupe(u8, text) catch return;
        if (slot.len != 0) self.gpa.free(slot.*);
        slot.* = owned;
    }

    /// Answer a held download offer. The path decision is THIS side's,
    /// always: the helper only writes where it is told, and an offer
    /// nobody answers is a file that never appears.
    fn onDownloadOffer(self: *Engine, ev: proto.EvDownloadOffer) void {
        var d: *Download = blk: {
            if (ev.req != 0) {
                if (self.download(ev.req)) |existing| break :blk existing;
            }
            // Page-initiated (or an echo this client no longer knows):
            // it still gets a record, so it is reportable and lands on
            // disk rather than being held forever.
            self.trimDownloads();
            const url_owned = self.gpa.dupe(u8, ev.url) catch {
                self.send(proto.DownloadDecide{ .view = ev.view, .id = ev.id, .path = "" }) catch {};
                return;
            };
            self.downloads.append(self.gpa, .{
                .req = self.nextDownloadReq(),
                .view = ev.view,
                .url = url_owned,
                .started_ms = clock.nowMs(),
            }) catch {
                self.gpa.free(url_owned);
                self.send(proto.DownloadDecide{ .view = ev.view, .id = ev.id, .path = "" }) catch {};
                return;
            };
            break :blk &self.downloads.items[self.downloads.items.len - 1];
        };
        d.id = ev.id;
        d.view = ev.view;
        d.total = ev.total;
        if (ev.name.len != 0) self.setDownloadStr(&d.name, ev.name);
        if (ev.mime.len != 0) self.setDownloadStr(&d.mime, ev.mime);
        if (d.terminal()) {
            self.send(proto.DownloadDecide{ .view = ev.view, .id = ev.id, .path = "" }) catch {};
            return;
        }
        if (d.path.len == 0) {
            var dir_buf: [4096]u8 = undefined;
            const dir = downloadDirZ(&dir_buf) orelse {
                self.send(proto.DownloadDecide{ .view = ev.view, .id = ev.id, .path = "" }) catch {};
                d.failed = true;
                d.fail_reason = "no download directory could be resolved (is HOME set?)";
                return;
            };
            var path_buf: [4608]u8 = undefined;
            const chosen = uniqueDownloadPath(&path_buf, dir, safeLeaf(if (ev.name.len != 0) ev.name else "download")) orelse {
                self.send(proto.DownloadDecide{ .view = ev.view, .id = ev.id, .path = "" }) catch {};
                d.failed = true;
                d.fail_reason = "no free file name in the download directory";
                return;
            };
            self.setDownloadStr(&d.path, chosen);
            if (d.path.len == 0) {
                self.send(proto.DownloadDecide{ .view = ev.view, .id = ev.id, .path = "" }) catch {};
                d.failed = true;
                d.fail_reason = "out of memory";
                return;
            }
        } else {
            // A caller-chosen path: its directory must exist before the
            // engine writes into it, or the download fails with an
            // engine error nobody can act on.
            pathz.makeParentDirs(d.path) catch {};
        }
        self.send(proto.DownloadDecide{ .view = ev.view, .id = ev.id, .path = d.path }) catch {
            d.failed = true;
            d.fail_reason = "the browser helper stopped before the download could start";
            return;
        };
        d.decided = true;
    }

    fn onDownloadProgress(self: *Engine, ev: proto.EvDownloadProgress) void {
        const d = blk: {
            if (ev.id != 0) {
                if (self.downloadById(ev.view, ev.id)) |found| break :blk found;
            }
            // id 0 = the helper refused a `download_start` outright.
            if (ev.req != 0) {
                if (self.download(ev.req)) |found| break :blk found;
            }
            return;
        };
        if (ev.received > d.received) d.received = ev.received;
        if (ev.total > 0) d.total = ev.total;
        if (ev.failed != 0 and !d.done) {
            d.failed = true;
            if (d.fail_reason.len == 0) d.fail_reason = if (ev.id == 0)
                "the browser did not start a download for that url (it may have navigated to it, or refused the scheme)"
            else
                "the browser engine canceled or interrupted the transfer";
        } else if (ev.done != 0) {
            d.done = true;
        }
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
            .eval => self.sendSemantic(request, proto.SemEval{
                .view = view_id,
                .flags = req.flags,
                .timeout_ms = req.timeout_ms,
                .code = .{ .s = req.arg },
                .max_str = req.max_str,
            }),
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
                self.cap_presenter = false;
                self.cap_observe = false;
                self.cap_downloads = false;
                self.cap_download_start = false;
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
                    if (std.mem.eql(u8, cap, proto.CAP_MULTI_CLIENT)) self.cap_multi_client = true;
                    if (std.mem.eql(u8, cap, proto.CAP_PRESENTER)) self.cap_presenter = true;
                    if (std.mem.eql(u8, cap, proto.CAP_OBSERVE)) self.cap_observe = true;
                    if (std.mem.eql(u8, cap, proto.CAP_POPUP_OPEN)) self.cap_popup_open = true;
                    if (std.mem.eql(u8, cap, proto.CAP_DOWNLOADS)) self.cap_downloads = true;
                    if (std.mem.eql(u8, cap, proto.CAP_DOWNLOAD_START)) self.cap_download_start = true;
                }
                // Headless: allow real popups for the whole connection.
                // A cancelled popup makes window.open return null, which
                // is what breaks every federated sign-in at its last
                // step; there is no user here to protect from one.
                if (self.cap_popup_open) {
                    self.send(proto.PopupPolicySet{
                        .view = 0,
                        .mode = proto.popup_mode_allow,
                    }) catch {};
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
            .ev_page_popup => {
                const ev = proto.decode(proto.EvPagePopup, frame.payload) catch return;
                if (ev.state == proto.page_popup_opened) {
                    // A popup the helper really opened, opener intact.
                    // Adopting it is what makes an OAuth flow work
                    // headlessly at all: it is the window the identity
                    // provider posts its result back through.
                    self.adoptPopupView(ev) catch {
                        self.send(proto.ViewDestroy{ .view = ev.popup_view }) catch {};
                    };
                } else if (self.findView(ev.popup_view)) |v| {
                    self.abandonView(v);
                }
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
                            self.loadStarted(v, if (ev.url.len > 0) ev.url else (v.url orelse ""));
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
            .ev_load_error => {
                const ev = proto.decode(proto.EvLoadError, frame.payload) catch return;
                if (self.findView(ev.view)) |v| {
                    if (v.load_error) |*old| old.free(self.gpa);
                    v.load_error = navfault.LoadErrRec.init(self.gpa, ev) catch null;
                }
            },
            .ev_cert_error => {
                // The helper HOLDS the request until this is answered
                // and nobody else is here to answer it: a headless
                // client that dropped the event left every self-signed
                // device hanging forever with `loading:true`. Fail
                // closed unless the caller named THIS certificate.
                const ev = proto.decode(proto.EvCertError, frame.payload) catch return;
                if (self.findView(ev.view)) |v| {
                    const accept = v.accept_fingerprint != null and ev.fingerprint.len > 0 and
                        std.ascii.eqlIgnoreCase(v.accept_fingerprint.?, ev.fingerprint);
                    if (v.cert) |*old| old.free(self.gpa);
                    v.cert = navfault.CertRec.init(self.gpa, ev, if (accept) .accepted else .refused) catch null;
                    self.send(proto.CertDecision{ .view = ev.view, .proceed = if (accept) 1 else 0 }) catch {};
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
            .ev_download_offer => {
                const ev = proto.decode(proto.EvDownloadOffer, frame.payload) catch return;
                self.onDownloadOffer(ev);
            },
            .ev_download_progress => {
                const ev = proto.decode(proto.EvDownloadProgress, frame.payload) catch return;
                self.onDownloadProgress(ev);
            },
            .ev_console => {
                const ev = proto.decode(proto.EvConsole, frame.payload) catch return;
                if (self.findView(ev.view)) |v| self.pushConsole(v, ev.level, ev.msg);
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

test "an offer for an asked-for download is DECIDED into the caller's path" {
    const gpa = std.testing.allocator;
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null, .{});
    defer {
        eng.state = .idle;
        eng.fd = -1;
        eng.deinit();
    }
    const v = try gpa.create(View);
    v.* = .{ .id = 1, .w = 100, .h = 100 };
    try eng.views.append(gpa, v);

    // A pipe stands in for the helper socket: the DECIDE frame is the
    // thing under test, and dropping it is the bug (the engine then
    // holds the download forever and nothing lands on disk).
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.SkipZigTest;
    defer _ = c.close(fds[0]);
    eng.fd = fds[1];
    eng.state = .ready;

    try eng.downloads.append(gpa, .{
        .req = 5,
        .view = 1,
        .url = try gpa.dupe(u8, "https://x.test/f.bin"),
        .path = try gpa.dupe(u8, "/tmp/webdrive-test/asked.bin"),
    });
    eng.onDownloadOffer(.{
        .view = 1,
        .id = 9,
        .total = 10,
        .url = "https://x.test/f.bin",
        .name = "f.bin",
        .mime = "application/octet-stream",
        .req = 5,
    });
    const d = eng.download(5).?;
    try std.testing.expect(d.decided);
    try std.testing.expectEqual(@as(u32, 9), d.id);
    try std.testing.expectEqualStrings("f.bin", d.name);

    var buf: [512]u8 = undefined;
    const n = c.read(fds[0], &buf, buf.len);
    try std.testing.expect(n > 0);
    var reader = proto.Reader.init(buf[0..@intCast(n)]);
    const frame = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.download_decide, frame.tag);
    const decide = try proto.decode(proto.DownloadDecide, frame.payload);
    try std.testing.expectEqualStrings("/tmp/webdrive-test/asked.bin", decide.path);

    // Progress, then a terminal frame: the state a poller reads.
    eng.onDownloadProgress(.{ .view = 1, .id = 9, .received = 4, .total = 10, .done = 0, .failed = 0, .req = 5 });
    try std.testing.expectEqual(@as(u64, 4), eng.download(5).?.received);
    eng.onDownloadProgress(.{ .view = 1, .id = 9, .received = 10, .total = 10, .done = 1, .failed = 0, .req = 5 });
    try std.testing.expect(eng.download(5).?.done);

    // A start the helper refused outright: id 0 answers the REQUEST,
    // so a caller waiting on the file is never waiting on silence.
    try eng.downloads.append(gpa, .{ .req = 6, .view = 1, .url = try gpa.dupe(u8, "https://x.test/g.bin") });
    eng.onDownloadProgress(.{ .view = 1, .id = 0, .received = 0, .total = 0, .done = 0, .failed = 1, .req = 6 });
    const refused = eng.download(6).?;
    try std.testing.expect(refused.failed);
    try std.testing.expect(refused.fail_reason.len > 0);

    // A helper that dies mid-transfer fails what is in flight rather
    // than leaving it running forever.
    try eng.downloads.append(gpa, .{ .req = 7, .view = 1, .url = try gpa.dupe(u8, "https://x.test/h.bin") });
    eng.failDownloads("gone");
    try std.testing.expect(eng.download(7).?.failed);
    try std.testing.expect(eng.download(5).?.done); // a finished one is untouched
}

test "a suggested download name is a leaf, and an existing file is never overwritten" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings("f.bin", Engine.safeLeaf("f.bin"));
    // A path in the engine's suggested name must never escape the
    // download directory.
    try std.testing.expectEqualStrings("passwd", Engine.safeLeaf("../../etc/passwd"));
    try std.testing.expectEqualStrings("download", Engine.safeLeaf(".."));
    try std.testing.expectEqualStrings("download", Engine.safeLeaf(""));

    const dir = "/tmp/webdrive-uniq-test";
    var z: [256:0]u8 = undefined;
    const zp = std.fmt.bufPrintZ(&z, "{s}", .{dir}) catch unreachable;
    _ = c.mkdir(zp.ptr, 0o700);
    defer pathz.removeTree(dir);
    const first = Engine.uniqueDownloadPath(&buf, dir, "f.bin").?;
    try std.testing.expectEqualStrings("/tmp/webdrive-uniq-test/f.bin", first);
    var fz: [512:0]u8 = undefined;
    const fzp = std.fmt.bufPrintZ(&fz, "{s}", .{first}) catch unreachable;
    const f = c.fopen(fzp.ptr, "wb") orelse return error.SkipZigTest;
    _ = c.fclose(f);
    const second = Engine.uniqueDownloadPath(&buf, dir, "f.bin").?;
    try std.testing.expectEqualStrings("/tmp/webdrive-uniq-test/f (1).bin", second);
}

test "console mirror: bounded, drop-oldest, paged by id" {
    const gpa = std.testing.allocator;
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null, .{});
    defer {
        eng.state = .idle;
        eng.deinit();
    }
    const v = try gpa.create(View);
    v.* = .{ .id = 1, .w = 100, .h = 100 };
    try eng.views.append(gpa, v);

    var i: usize = 0;
    while (i < CONSOLE_CAP + 5) : (i += 1) eng.pushConsole(v, 2, "line");
    const tail = try eng.consoleTail(1, 0);
    try std.testing.expectEqual(@as(usize, CONSOLE_CAP), tail.lines.len);
    try std.testing.expectEqual(@as(u32, 5), tail.dropped);
    // The oldest retained id is 6: 1..5 were dropped.
    try std.testing.expectEqual(@as(u32, 6), tail.lines[0].id);
    const page = try eng.consoleTail(1, tail.lines[tail.lines.len - 1].id - 2);
    try std.testing.expectEqual(@as(usize, 2), page.lines.len);
    const drained = try eng.consoleTail(1, tail.next - 1);
    try std.testing.expectEqual(@as(usize, 0), drained.lines.len);
    try std.testing.expectError(error.NoView, eng.consoleTail(9, 0));

    // A line past the byte bound is truncated, never refused.
    var big: [CONSOLE_LINE_MAX + 100]u8 = @splat('x');
    eng.pushConsole(v, 3, &big);
    const last = try eng.consoleTail(1, 0);
    try std.testing.expectEqual(@as(usize, CONSOLE_LINE_MAX), last.lines[last.lines.len - 1].text.len);
}

test "a snapshot reply is exactly the helper's coalesced answer; strays are dropped" {
    const gpa = std.testing.allocator;
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null, .{});
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
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null, .{});
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
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null, .{});
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
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null, .{});
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
        self.eng = try Engine.init(gpa, "/tmp/webdrive-test", "unit", null, .{});
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
        pathz.removeTree(self.stateDir());
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

/// The first frame of tag `tag` in `bytes`, decoded.
fn frameOf(comptime T: type, bytes: []const u8) ?T {
    var reader = proto.Reader.init(bytes);
    while ((reader.next() catch null)) |frame| {
        if (frame.tag == T.tag) return proto.decode(T, frame.payload) catch null;
    }
    return null;
}

test "ev_cert_error is answered: refused by default, accepted only for the named fingerprint" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    var buf: [8192]u8 = undefined;

    const v = try p.eng.openViewIn("https://10.0.0.1/", 800, 600, .default, null);
    _ = p.drain(&buf);
    const fp = "ab" ** 32;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try proto.encodePayload(gpa, &payload, proto.EvCertError{
        .view = v.id,
        .code = -202,
        .url = "https://10.0.0.1/",
        .host = "10.0.0.1",
        .msg = "CERT_AUTHORITY_INVALID",
        .subject = "CN=fritz.box",
        .issuer = "CN=fritz.box",
        .fingerprint = fp,
    });

    // Nobody opted in: the hold is REFUSED at once (a dropped event
    // used to leave the load hanging forever) and the verdict recorded.
    p.eng.dispatch(.{ .tag = .ev_cert_error, .payload = payload.items });
    try std.testing.expect(v.cert.?.verdict == .refused);
    try std.testing.expectEqualStrings("CERT_AUTHORITY_INVALID", v.cert.?.msg);
    try std.testing.expectEqualStrings(fp, v.cert.?.fingerprint);
    const refused = frameOf(proto.CertDecision, p.drain(&buf)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), refused.proceed);

    // The engine then fails the load; both records explain it.
    var err_payload: std.ArrayList(u8) = .empty;
    defer err_payload.deinit(gpa);
    try proto.encodePayload(gpa, &err_payload, proto.EvLoadError{
        .view = v.id,
        .code = -202,
        .url = "https://10.0.0.1/",
        .msg = "ERR_CERT_AUTHORITY_INVALID",
    });
    p.eng.dispatch(.{ .tag = .ev_load_error, .payload = err_payload.items });
    try std.testing.expectEqual(@as(i32, -202), v.load_error.?.code);

    // Opting in names ONE certificate, case-insensitively; a string
    // that cannot be a fingerprint is refused at the call.
    try std.testing.expectError(error.InvalidFingerprint, p.eng.setAcceptCert(v.id, "abc"));
    try p.eng.setAcceptCert(v.id, "AB" ** 32);
    p.eng.dispatch(.{ .tag = .ev_cert_error, .payload = payload.items });
    try std.testing.expect(v.cert.?.verdict == .accepted);
    const accepted = frameOf(proto.CertDecision, p.drain(&buf)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), accepted.proceed);

    // A started load on the same host keeps the accepted verdict (the
    // page stands on it) and drops the stale failure; another host
    // drops the verdict too.
    var load_payload: std.ArrayList(u8) = .empty;
    defer load_payload.deinit(gpa);
    try proto.encodePayload(gpa, &load_payload, proto.EvLoad{
        .view = v.id,
        .state = @intFromEnum(proto.LoadState.started),
        .url = "https://10.0.0.1/login",
    });
    p.eng.dispatch(.{ .tag = .ev_load, .payload = load_payload.items });
    try std.testing.expect(v.cert != null and v.cert.?.verdict == .accepted);
    try std.testing.expect(v.load_error == null);
    load_payload.clearRetainingCapacity();
    try proto.encodePayload(gpa, &load_payload, proto.EvLoad{
        .view = v.id,
        .state = @intFromEnum(proto.LoadState.started),
        .url = "https://other.test/",
    });
    p.eng.dispatch(.{ .tag = .ev_load, .payload = load_payload.items });
    try std.testing.expect(v.cert == null);

    // A different certificate on the opted-in view is still refused.
    var other: std.ArrayList(u8) = .empty;
    defer other.deinit(gpa);
    try proto.encodePayload(gpa, &other, proto.EvCertError{
        .view = v.id,
        .code = -201,
        .url = "https://other.test/",
        .host = "other.test",
        .msg = "CERT_DATE_INVALID",
        .subject = "",
        .issuer = "",
        .fingerprint = "cd" ** 32,
    });
    p.eng.dispatch(.{ .tag = .ev_cert_error, .payload = other.items });
    try std.testing.expect(v.cert.?.verdict == .refused);
    const again = frameOf(proto.CertDecision, p.drain(&buf)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 0), again.proceed);
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
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null, null, .{});
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

test "NetPolicyPatch.effective carries every said field, checked field by field" {
    // Every value differs from NetPolicy's default, so a field that
    // effective() failed to copy would read back as the default.
    const full = NetPolicyPatch{
        .allow_top = &.{"a.example"},
        .allow_sub = &.{"b.example"},
        .block_types = netpolicy.typeBit("image").?,
        .allow_schemes = netpolicy.schemeBit("wss").?,
        .allow_private = true,
        .block_ads = false,
        .max_requests = 11,
        .max_bytes = 22,
        .max_navigations = 33,
        .deadline_ms = 44,
    };
    const eff = full.effective();
    inline for (std.meta.fields(NetPolicy)) |f| {
        const want = @field(full, f.name).?;
        const got = @field(eff, f.name);
        if (@typeInfo(f.type) == .optional) {
            try std.testing.expectEqual(want, got.?);
        } else if (@typeInfo(f.type) == .pointer) {
            try std.testing.expectEqual(want.len, got.len);
            try std.testing.expectEqualStrings(want[0], got[0]);
        } else {
            try std.testing.expectEqual(want, got);
        }
    }

    // A fully-null patch is byte-for-byte NetPolicy's defaults.
    const none = (NetPolicyPatch{}).effective();
    const dflt = NetPolicy{};
    inline for (std.meta.fields(NetPolicy)) |f| {
        if (@typeInfo(f.type) == .pointer) {
            try std.testing.expectEqual(@as(usize, 0), @field(none, f.name).len);
        } else {
            try std.testing.expectEqual(@field(dflt, f.name), @field(none, f.name));
        }
    }
}

test "a present empty host list narrows a live view to no hosts; an absent one is untouched" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.cap_net_policy = true;
    var buf: [16384]u8 = undefined;

    const pol = NetPolicy{
        .allow_top = &.{ "site.example", "cdn.example" },
        .allow_sub = &.{"static.example"},
        .block_types = netpolicy.typeBit("image").?,
    };
    const v = try p.eng.openViewIn("https://site.example/", 800, 600, .default, &pol);
    _ = p.drain(&buf);

    // Absent lists and an explicit empty block_types move nothing.
    const r0 = try p.eng.tightenViewPolicy(v.id, &.{ .block_types = 0 });
    try std.testing.expectEqual(@as(usize, 0), r0.n_tightened);
    try std.testing.expectEqual(@as(usize, 0), r0.n_ignored);
    try std.testing.expectEqual(@as(usize, 2), v.pol.?.allow_top.len);
    try std.testing.expectEqual(@as(usize, 1), v.pol.?.allow_sub.len);
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);

    // An explicit empty top-level list is the literal tighten: no hosts.
    // The subresource list was not said and survives.
    const r1 = try p.eng.tightenViewPolicy(v.id, &.{ .allow_top = &.{} });
    try std.testing.expectEqual(@as(usize, 1), r1.n_tightened);
    try std.testing.expectEqualStrings("allow_hosts", r1.tightened[0]);
    try std.testing.expectEqual(@as(usize, 0), r1.n_ignored);
    try std.testing.expectEqual(@as(usize, 0), v.pol.?.allow_top.len);
    try std.testing.expectEqual(@as(usize, 1), v.pol.?.allow_sub.len);
    try std.testing.expectEqual(netpolicy.typeBit("image").?, v.pol.?.block_types);

    const bytes = p.drain(&buf);
    var reader = proto.Reader.init(bytes);
    const frame = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.net_policy_set, frame.tag);
    const set = try proto.NetPolicySet.decodeAlloc(frame.payload, gpa);
    defer gpa.free(set.allow_top);
    defer gpa.free(set.allow_sub);
    try std.testing.expectEqual(@as(usize, 0), set.allow_top.len);
    try std.testing.expectEqual(@as(usize, 1), set.allow_sub.len);

    // Already empty: saying it again changes nothing and sends nothing.
    const r2 = try p.eng.tightenViewPolicy(v.id, &.{ .allow_top = &.{} });
    try std.testing.expectEqual(@as(usize, 0), r2.n_tightened);
    try std.testing.expectEqual(@as(usize, 0), r2.n_ignored);
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);
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
