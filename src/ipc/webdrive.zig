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
const diagnostic = @import("../web/diagnostic.zig");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const pathz = @import("../util/pathz.zig");
const strz = @import("../util/strz.zig");
const muxclient = @import("../mux/client.zig");
const fsserve = @import("../mux/fsserve.zig");
const display = @import("../mux/display.zig");
const proto = @import("../web/protocol.zig");
const untrusted_env = @import("../web/untrusted_env.zig");
comptime {
    // untrusted_env spells the presenter switch itself to stay import-free.
    if (!untrusted_env.dropped(proto.PRESENTER_ENV)) @compileError("untrusted helpers must not inherit the presenter switch");
}
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
const download_policy = @import("../web/download.zig");
const capture = @import("../web/capture.zig");
const webroute = @import("../web/route.zig");
const socksbridge = @import("socksbridge.zig");
const mux_cli = @import("mux_cli.zig");

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

/// After the graceful window, how long an untrusted cleanup owner gets to
/// SIGKILL its descendants and delete the private root once its lifetime
/// fence closes and it is sent SIGTERM; past it the owner itself is
/// SIGKILLed and the root is left for a later supervisor's sweep.
const UNTRUSTED_RETIRE_MS: i64 = 2_000;

/// Wait slice for a child when no pidfd is available (pre-5.3 kernels).
const CHILD_POLL_FALLBACK_MS: i64 = 20;

/// `SK_WEB_SUPERVISOR_CLEANUP_FAILED` in vendor/web_supervisor.h: the
/// cleanup owner exhausted its bounded deletion attempts.
const SUPERVISOR_CLEANUP_FAILED: u8 = 251;

/// Directory under the per-user runtime dir that holds untrusted roots.
/// Short on purpose: see `UNTRUSTED_TMPDIR_MAX`.
const UNTRUSTED_PARENT = "sketerm/u";

/// `SK_WEB_SUPERVISOR_TMPDIR_MAX` in vendor/web_supervisor.h: the longest
/// `<root>/t` the browser may get as $TMPDIR, because Chromium binds
/// $TMPDIR/org.chromium.Chromium.XXXXXX/SingletonSocket (about 46 more
/// bytes) and a unix socket path caps at 108.
const UNTRUSTED_TMPDIR_MAX = 60;

/// Random bytes in a root's name (16 hex chars, the supervisor's sweep
/// pattern). The 0700 parent provides privacy; the name only uniqueness.
const UNTRUSTED_NAME_BYTES = 8;

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
    max_fps: ?u16 = null,
    id: u32,
    w: u16,
    h: u16,
    emulation: Emulation = .{},
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
    // pixels ONLY as an shm memfd (`frames-shm`; software compositing means
    // `frames-dmabuf` never applies), and every fd/mmap
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
    pol_wait_serial: u32 = 0,
    pol_reply: ?proto.EvNetPolicy = null,
    pol_seen: u32 = 0,
    pol_active: bool = false,
    /// The helper refused our install/update serial; the affected view must close.
    pol_install_failed: bool = false,
    /// `proto.NetReason` byte; nonzero once a budget latched.
    pol_exhausted: u8 = 0,
    pol_requests: u32 = 0,
    pol_bytes: u64 = 0,
    pol_navigations: u32 = 0,
    pol_ms_left: u32 = 0,
    pol_denied: [proto.NREASONS]u32 = @splat(0),

    // Response-body capture (capability "capture"). The filter the view
    // was opened with (owned), and the last capture_list / capture_body
    // payloads, parked raw (owned) for the synchronous verbs.
    cap: ?CaptureFilter = null,
    cap_serial: u32 = 0,
    /// The helper answered `refused` for our serial: it could not hold
    /// the capture. The open must fail closed.
    cap_install_failed: bool = false,
    cap_disabled: bool = false,
    cap_list: ?[]u8 = null,
    cap_body: ?[]u8 = null,

    stream_request: u32 = 0,
    stream_reply: ?[]u8 = null,
    /// From a successful open until `ev_stream_closed`: one stream per view.
    streaming: bool = false,

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
    /// The helper's own one-shot reload after `ERR_NETWORK_CHANGED`
    /// (`ev_load_retry`), kept until THIS client's next navigation
    /// request (`navfault.navigationRequested`), so the caller who asked
    /// for the page learns its load was interrupted and healed.
    load_retry: ?navfault.LoadErrRec = null,
    /// SHA-256 (lowercase hex) of the ONE certificate this view may
    /// proceed on. Every other certificate error is refused; nothing is
    /// remembered engine-side either (`proto.CertDecision`). Owned.
    accept_fingerprint: ?[]u8 = null,
    /// How many observers (a GUI's Watch / Take control) watch this view
    /// and how many of them drive it, from `ev_view_watchers`. Only a
    /// fact when the helper advertised `observe-notify`
    /// (`Engine.watchKnown`); 0 otherwise means "not told".
    watchers: u16 = 0,
    controllers: u16 = 0,
    /// When either count last changed (monotonic ms): the end of a watch
    /// counts as the tab being used, so an idle countdown starts there.
    watch_changed_ms: i64 = 0,

    fn deinit(self: *View, gpa: std.mem.Allocator) void {
        for (self.console.items) |line| gpa.free(line.text);
        self.console.deinit(gpa);
        if (self.cert) |*rec| rec.free(gpa);
        if (self.load_error) |*rec| rec.free(gpa);
        if (self.load_retry) |*rec| rec.free(gpa);
        if (self.accept_fingerprint) |f| gpa.free(f);
        if (self.url) |u| gpa.free(u);
        if (self.title) |t| gpa.free(t);
        if (self.profile) |p| gpa.free(p);
        if (self.create_failed) |f| gpa.free(f);
        if (self.last_eval) |e| gpa.free(e);
        if (self.pol) |*p| freePolicy(gpa, p);
        if (self.cap) |*f| freeCapture(gpa, f);
        if (self.cap_list) |b| gpa.free(b);
        if (self.cap_body) |b| gpa.free(b);
        if (self.stream_reply) |b| gpa.free(b);
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
pub const ProfileSpec = union(enum) {
    default,
    named: []const u8,
    ephemeral,

    /// The identity as one human-readable phrase (`default cookie jar`,
    /// `profile 'work'`, `a throwaway identity`), written into `buf`.
    pub fn describe(self: ProfileSpec, buf: []u8) []const u8 {
        return switch (self) {
            .default => "the default cookie jar",
            .ephemeral => "a throwaway identity",
            .named => |n| std.fmt.bufPrint(buf, "profile '{s}'", .{n}) catch "a named profile",
        };
    }
};

/// Why a `web_open` that NAMES the browser cannot be served by the live
/// one: the browser already carries another name, or that name with
/// another identity. Either would silently re-label tabs other callers
/// are working in.
pub const LabelConflict = union(enum) {
    none,
    /// The browser's current name.
    rename: []const u8,
    /// The browser's identity, as `ProfileSpec.describe` words it.
    identity: []const u8,
};

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
    untrusted: bool = false,
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
    untrusted: ?bool = null,
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
    PolicyAckUnsupported,
    PolicyRefused,
    PolicyAckTimeout,
    PolicyTooManyViews,
    NoPolicy,
};

pub const Emulation = struct {
    color_scheme: ?proto.ColorScheme = null,
    reduced_motion: ?proto.ReducedMotion = null,
    device_scale_factor: ?f64 = null,

    pub fn present(self: Emulation) bool {
        return self.color_scheme != null or self.reduced_motion != null or self.device_scale_factor != null;
    }

    pub fn scale(self: Emulation) u16 {
        return if (self.device_scale_factor) |s| @intFromFloat(@round(s * 1000)) else 1000;
    }

    pub fn valid(self: Emulation) bool {
        if (self.color_scheme == .unchanged or self.reduced_motion == .unchanged) return false;
        if (self.device_scale_factor) |s| return std.math.isFinite(s) and s >= 0.5 and s <= 4;
        return true;
    }
};

/// Deep-copy a policy so a stored one outlives its caller's arena.
/// A response-body CAPTURE as the client speaks it: what `web_open`
/// parsed and what `capture_set` serializes. Field semantics live in
/// `web/capture.zig` (the filter's home); this is the transportable
/// value. Empty lists and strings mean "no restriction"; `types` 0
/// means every resource class.
pub const CaptureFilter = struct {
    types: u16 = capture.DEFAULT_TYPES,
    hosts: []const []const u8 = &.{},
    methods: []const []const u8 = &.{},
    mime_prefixes: []const []const u8 = &.{},
    url_contains: []const u8 = "",
    url_regex: []const u8 = "",
    max_body: u32 = capture.DEFAULT_MAX_BODY,
    max_total: u64 = capture.DEFAULT_MAX_TOTAL,
};

/// Deep-copy a capture filter so the view's copy outlives the caller's
/// arena.
fn dupeCapture(gpa: std.mem.Allocator, f: CaptureFilter) !CaptureFilter {
    var out = f;
    out.hosts = try dupeHostList(gpa, f.hosts);
    errdefer freeHostList(gpa, out.hosts);
    out.methods = try dupeHostList(gpa, f.methods);
    errdefer freeHostList(gpa, out.methods);
    out.mime_prefixes = try dupeHostList(gpa, f.mime_prefixes);
    errdefer freeHostList(gpa, out.mime_prefixes);
    out.url_contains = try gpa.dupe(u8, f.url_contains);
    errdefer gpa.free(out.url_contains);
    out.url_regex = try gpa.dupe(u8, f.url_regex);
    return out;
}

fn freeCapture(gpa: std.mem.Allocator, f: *CaptureFilter) void {
    freeHostList(gpa, f.hosts);
    freeHostList(gpa, f.methods);
    freeHostList(gpa, f.mime_prefixes);
    gpa.free(f.url_contains);
    gpa.free(f.url_regex);
    f.* = .{};
}

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
/// one view across all of them.
///
/// They are also RANDOM and NEVER REUSED for the life of the process.
/// Several assistants (sub-agents) share one server's browser; with
/// counting ids `1, 2, 3` one of them could act on another's tab by a
/// guess or a typo, and a closed tab's id came back as somebody else's.
/// The id is the wire view id too, so it stays inside the window a
/// `multi-client` helper accepts (`proto.CONN_ID_WINDOW`).
var g_view_ids: ViewIds = .{};

/// The set of client view ids this process has ever issued, one bit each.
const ViewIds = struct {
    const SPACE: u32 = proto.CONN_ID_WINDOW;
    issued: [SPACE / 8]u8 = @splat(0),
    count: u32 = 0,

    fn taken(self: *const ViewIds, id: u32) bool {
        return self.issued[id / 8] & (@as(u8, 1) << @intCast(id % 8)) != 0;
    }

    /// The first never-issued id at or after `start` (wrapping, 0 is
    /// never an id), marked issued; null once every id has been used.
    fn claim(self: *ViewIds, start: u32) ?u32 {
        if (self.count >= SPACE - 1) return null;
        var id = start % SPACE;
        while (true) : (id = (id + 1) % SPACE) {
            if (id == 0 or self.taken(id)) continue;
            self.issued[id / 8] |= @as(u8, 1) << @intCast(id % 8);
            self.count += 1;
            return id;
        }
    }
};

test "view ids are never reused and never 0, until the space runs out" {
    const t = std.testing;
    const ids = try t.allocator.create(ViewIds);
    defer t.allocator.destroy(ids);
    ids.* = .{};
    try t.expectEqual(@as(?u32, 5), ids.claim(5));
    // The same draw again lands on the next free id, never the old one.
    try t.expectEqual(@as(?u32, 6), ids.claim(5));
    try t.expectEqual(@as(?u32, 1), ids.claim(0));
    try t.expectEqual(@as(?u32, 2), ids.claim(ViewIds.SPACE));
    // A draw at the top of the space wraps past 0.
    try t.expectEqual(@as(?u32, ViewIds.SPACE - 1), ids.claim(ViewIds.SPACE - 1));
    try t.expectEqual(@as(?u32, 3), ids.claim(ViewIds.SPACE - 1));
    ids.count = ViewIds.SPACE - 1;
    try t.expect(ids.claim(77) == null);
}

/// Outcome of retiring an untrusted helper's cleanup owner.
pub const UntrustedCleanup = enum {
    none,
    /// The owner exited after deleting the private root.
    deleted,
    /// The owner exhausted its bounded deletion attempts (`SUPERVISOR_CLEANUP_FAILED`).
    gave_up,
    /// The owner missed its retirement deadline and was SIGKILLed; the
    /// root is left for a later supervisor's sweep.
    owner_killed,
    /// The owner died by a signal, or someone else reaped it.
    unknown,
};

/// `CLOSE_RANGE_CLOEXEC` from linux/close_range.h. std's `CLOSE_RANGE`
/// packed struct numbers its bits from 0 (UNSHARE=1, CLOEXEC=2), but the
/// kernel's are 1<<1 and 1<<2, so it cannot be used here.
const CLOSE_RANGE_CLOEXEC: u32 = 1 << 2;

/// Mark every descriptor from `first` up close-on-exec. Fork-child safe:
/// raw syscalls and stack memory only. `how` exists so tests can force
/// the fallbacks a pre-5.11 kernel or a /proc-less system takes.
fn markCloexecFrom(first: c_int, how: CloexecPath) bool {
    const linux = std.os.linux;
    if (how == .close_range) {
        const rc = linux.syscall3(.close_range, @intCast(first), std.math.maxInt(u32), CLOSE_RANGE_CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => return true,
            .NOSYS, .INVAL => {},
            else => return false,
        }
    }
    if (how != .rlimit) proc: {
        const dir = c.open("/proc/self/fd", c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
        if (dir < 0) break :proc;
        defer _ = c.close(dir);
        var buf: [4096]u8 align(8) = undefined;
        while (true) {
            const n = linux.getdents64(dir, &buf, buf.len);
            if (linux.errno(n) != .SUCCESS) break :proc;
            if (n == 0) return true;
            var off: usize = 0;
            while (off < n) {
                const ent: *align(1) const linux.dirent64 = @ptrCast(&buf[off]);
                const name_ptr: [*:0]const u8 = @ptrCast(&buf[off + @offsetOf(linux.dirent64, "name")]);
                off += ent.reclen;
                const fd = std.fmt.parseInt(c_int, std.mem.span(name_ptr), 10) catch continue;
                if (fd < first or fd == dir) continue;
                if (c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC) < 0) return false;
            }
        }
    }
    // Neither: every descriptor the soft limit allows; EBADF is expected.
    var lim: c.struct_rlimit = undefined;
    if (c.getrlimit(c.RLIMIT_NOFILE, &lim) != 0) return false;
    const top: c_int = @intCast(@min(lim.rlim_cur, @as(c.rlim_t, std.math.maxInt(c_int))));
    var fd = first;
    while (fd < top) : (fd += 1) _ = c.fcntl(fd, c.F_SETFD, c.FD_CLOEXEC);
    return true;
}

const CloexecPath = enum { close_range, proc, rlimit };

/// A close-on-exec pidfd for an unreaped child, or -1 where the kernel
/// (pre-5.3) or platform has none and waits fall back to polling.
fn pidfdOpen(pid: c.pid_t) c_int {
    if (comptime @import("builtin").os.tag != .linux) return -1;
    const linux = std.os.linux;
    const rc = linux.pidfd_open(pid, 0);
    if (linux.errno(rc) != .SUCCESS) return -1;
    return @intCast(rc);
}

/// A child's environment, assembled before fork: nothing may allocate
/// between fork and exec while the MCP watchdog thread runs.
const ChildEnv = struct {
    arena: std.heap.ArenaAllocator,
    envp: [*:null]const ?[*:0]const u8,

    fn deinit(self: *ChildEnv) void {
        self.arena.deinit();
    }

    /// The inherited environment minus every `dropped` name, plus `sets`
    /// (which replace any inherited value).
    fn build(gpa: std.mem.Allocator, dropped: *const fn ([]const u8) bool, sets: []const [2][]const u8) !ChildEnv {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        var list: std.ArrayList(?[*:0]const u8) = .empty;
        var i: usize = 0;
        outer: while (std.c.environ[i]) |entry| : (i += 1) {
            const text = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, text, '=') orelse continue;
            const name = text[0..eq];
            if (dropped(name)) continue;
            for (sets) |kv| if (std.mem.eql(u8, kv[0], name)) continue :outer;
            try list.append(a, entry);
        }
        for (sets) |kv| {
            const joined = try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ kv[0], kv[1] }, 0);
            try list.append(a, joined.ptr);
        }
        try list.append(a, null);
        return .{ .arena = arena, .envp = @ptrCast(list.items.ptr) };
    }
};

fn keepAll(_: []const u8) bool {
    return false;
}

/// Display, audio and bus endpoints a session helper must not inherit.
fn sessionDropped(name: []const u8) bool {
    for ([_][]const u8{ "WAYLAND_SOCKET", "DISPLAY", "XAUTHORITY" }) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The per-user directory untrusted roots live in, created 0700. Refused
/// unless the runtime dir is closed to other users (or sticky) and both
/// sketerm levels are ours and closed to group/other writes.
fn untrustedParent(runtime: []const u8, buf: []u8) ?[:0]const u8 {
    const uid = c.getuid();
    var st: c.struct_stat = undefined;
    const rt = std.fmt.bufPrintZ(buf, "{s}", .{runtime}) catch return null;
    if (c.lstat(rt.ptr, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFDIR) return null;
    if (st.st_uid != uid and st.st_uid != 0) return null;
    if (st.st_mode & 0o022 != 0 and st.st_mode & c.S_ISVTX == 0) return null;
    const levels = [_]struct { suffix: []const u8, forbid: c_uint }{
        .{ .suffix = "sketerm", .forbid = 0o022 },
        .{ .suffix = UNTRUSTED_PARENT, .forbid = 0o077 },
    };
    var out: [:0]const u8 = rt;
    for (levels, 0..) |level, i| {
        out = std.fmt.bufPrintZ(buf, "{s}/{s}", .{ runtime, level.suffix }) catch return null;
        _ = c.mkdir(out.ptr, 0o700);
        if (c.lstat(out.ptr, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFDIR or st.st_uid != uid) return null;
        // Our own untrusted dir is tightened in place; its parent is ours
        // and closed to writes, so no one can swap it for a link meanwhile.
        if (i == levels.len - 1 and st.st_mode & level.forbid != 0) {
            if (c.chmod(out.ptr, 0o700) != 0 or c.lstat(out.ptr, &st) != 0) return null;
        }
        if (st.st_mode & level.forbid != 0) return null;
    }
    return out;
}

test "a named browser refuses a rename or an identity switch while it has tabs" {
    const t = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var e = Engine{ .gpa = arena, .dir = @constCast(""), .client_name = @constCast("") };
    // Nothing named yet: any name is fine.
    try t.expectEqual(LabelConflict.none, e.labelConflict("Scan A", .default));
    e.setBrowserLabelFor("Scan A", .{ .named = "work" });
    // No tabs: nobody works in it, so it may be renamed.
    try t.expectEqual(LabelConflict.none, e.labelConflict("Scan B", .default));
    const v = try arena.create(View);
    v.* = .{ .id = 3, .w = 1, .h = 1 };
    try e.views.append(arena, v);
    try t.expectEqualStrings("Scan A", e.labelConflict("Scan B", .{ .named = "work" }).rename);
    try t.expectEqualStrings("profile 'work'", e.labelConflict("Scan A", .default).identity);
    try t.expectEqualStrings("profile 'work'", e.labelConflict("Scan A", .ephemeral).identity);
    try t.expectEqual(LabelConflict.none, e.labelConflict("Scan A", .{ .named = "work" }));
}

/// A fresh, random, never-issued view id.
fn nextViewId() error{ NoEntropy, ViewIdsExhausted }!u32 {
    var raw: [4]u8 = undefined;
    if (c.getentropy(&raw, raw.len) != 0) return error.NoEntropy;
    return g_view_ids.claim(std.mem.readInt(u32, &raw, .little)) orelse error.ViewIdsExhausted;
}

pub const Engine = struct {
    default_max_fps: ?u16 = null,
    gpa: std.mem.Allocator,
    /// Directory holding the helper socket and its cache; owned.
    dir: []u8,
    /// Fixed when the engine is created: an engine never switches modes,
    /// so an ordinary helper can never be reused for untrusted content.
    untrusted: bool = false,
    /// This launch's private root, `<runtime>/sketerm/untrusted/<random>`;
    /// fresh per launch, so a leftover root never blocks the next one.
    private_dir: ?[]u8 = null,
    private_lifetime: c_int = -1,
    /// How the last untrusted teardown ended.
    untrusted_cleanup: UntrustedCleanup = .none,
    /// Teardown phases (graceful self-exit, then owner retirement); fields so
    /// tests can shorten them.
    untrusted_grace_ms: i64 = GRACEFUL_EXIT_MS,
    untrusted_retire_ms: i64 = UNTRUSTED_RETIRE_MS,
    mode_selected: bool = false,
    /// MCP instance name (`--name work`), which keys the profile store
    /// root; owned, null for an anonymous instance.
    instance: ?[]u8 = null,
    /// Hello identity ("sketerm-mcp" or "sketerm-mcp:<instance>"), so
    /// helper logs and a future viewer can attribute the session to an
    /// assistant rather than an anonymous client. Owned.
    client_name: []u8,
    browser_label: [161]u8 = @splat(0),
    /// `ProfileSpec.describe` of the open that set `browser_label`.
    label_identity: [96]u8 = @splat(0),
    presence_started_ms: i64 = 0,
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
    /// What the CURRENT helper advertised in `hello_ack`; empty before
    /// it and after the helper is lost. Everything reported from it
    /// (presenter, observe) is a reported fact, never inferred: a helper
    /// in session mode whose presenter failed to arm still says no.
    /// Profiles need BOTH `contexts` and `contexts-fail-closed`, since
    /// without the second an unknown context resolves through the shared
    /// jar invisibly; a `multi-client` helper that outlives the teardown
    /// grace is serving someone else and is abandoned, never signalled.
    caps: proto.Caps = .initEmpty(),
    /// Why this ROUTED helper serves nothing (`ev_route_refused`), owned;
    /// null while it serves. Cleared with the connection: a fresh helper
    /// tries its route again.
    route_refused: ?[]u8 = null,
    /// The loopback SOCKS5 -> mux bridge a `via:` engine's `--proxy`
    /// points at, created at the first start and kept across helper
    /// restarts (its port is baked into each spawn's argv).
    egress: ?*socksbridge.Egress = null,
    /// Downloads this engine has seen, page-initiated ones included.
    /// Bounded by `DOWNLOAD_CAP`, drop-oldest-finished.
    downloads: std.ArrayList(Download) = .empty,
    next_download_req: u32 = 1,
    next_sem_request: u32 = 1,
    next_stream_request: u32 = 1,
    /// Stamps every `net_policy_set`; `ev_net_policy` echoes it so a
    /// stale event for a replaced policy is ignorable.
    next_policy_serial: u32 = 1,
    /// Stamps every capture install; a `refused` answer names it.
    next_capture_serial: u32 = 1,
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
    /// `flush_req` bookkeeping (`saveProfiles`): the next token to send
    /// and the last one the engine answered with `ev_flushed`.
    flush_token_next: u32 = 1,
    flushed_token: u32 = 0,
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
    diagnostic: diagnostic.Capture = .{},
    broker_diagnostics: bool = false,

    /// Whether the current helper advertised `cap`.
    pub fn has(self: *const Engine, cap: proto.Cap) bool {
        return self.caps.contains(cap);
    }

    pub fn diagnosticReport(self: *Engine, arena: std.mem.Allocator) diagnostic.Report {
        if (self.diagnostic.id[0] == 0) {
            const stage = self.diagnostic.stage;
            self.diagnostic = diagnostic.Capture.record() catch return self.diagnostic.report();
            self.diagnostic.stage = stage;
        }
        if (self.broker_diagnostics) {
            if (self.remote) |*remote| {
                const stage = self.diagnostic.stage;
                if (remote.engineDiagnostic(arena)) |report| {
                    self.diagnostic.adoptReport(report);
                    if (self.helper_gen > 0) self.diagnostic.stage = stage;
                } else |_| {}
            }
        }
        return self.diagnostic.report();
    }

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
        if (self.untrusted) {
            const dir = self.private_dir orelse return null;
            return std.fmt.bufPrintZ(buf, "{s}/web{s}", .{ dir, ext }) catch null;
        }
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
        defer self.diagnostic.deinit();
        if (self.untrusted) self.stopUntrusted();
        self.dropConnection();
        if (self.pid > 0 and self.has(.multi_client) and self.remote != null) {
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
        if (self.pid > 0 and !self.untrusted) {
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
        self.teardownSession(!(self.has(.multi_client) and self.remote != null));
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
        if (self.route_refused) |r| self.gpa.free(r);
        self.route_refused = null;
        // After the helper: it was the bridge's only client.
        if (self.egress) |eg| eg.close();
        self.egress = null;
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
        // `stopUntrusted` above already released it; a root its owner could
        // not delete is swept by a later supervisor, never by this process.
        if (self.private_dir) |dir| self.gpa.free(dir);
        self.private_dir = null;
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
        if (self.untrusted) {
            self.setStoreReason("untrusted browsing permits only ephemeral identities and has no durable profile store", false);
            return;
        }
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
        return self.session != null and self.state == .ready and self.has(.presenter);
    }

    /// Whether a GUI can watch this engine's pages as browser pages:
    /// the live helper advertised `observe`.
    pub fn observeActive(self: *const Engine) bool {
        return self.state == .ready and self.has(.observe);
    }

    /// Whether `View.watchers` is a FACT for this helper: it reports
    /// watchers (`observe-notify`), or nobody can watch at all (no
    /// `observe`). False before a handshake and on an older helper that
    /// serves observers without telling the owner.
    pub fn watchKnown(self: *const Engine) bool {
        if (self.state != .ready) return false;
        return self.has(.observe_notify) or !self.has(.observe);
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
    pub fn writePresence(self: *Engine) void {
        // This file also locates the owner's watchable session. An adopted
        // connection has neither its pid nor its session; publishing our
        // local view state would erase the real owner's discovery record.
        if (self.state != .ready or self.owner != .self_spawned) return;
        if (self.presence_started_ms == 0) self.presence_started_ms = clock.nowMs();
        var path_z: [4096:0]u8 = undefined;
        const p = self.routePathZ(&path_z, ".json") orelse return;
        const url = if (self.findView(self.current)) |v| v.url orelse "" else "";
        const host = @import("../web/urlhost.zig").hostOf(url, .{ .require_scheme = true });
        const domain = if (host.len != 0) host else if (url.len != 0) "Local page" else if (self.views.items.len == 0) "Waiting for a page" else "Opening page";
        const body = std.json.Stringify.valueAlloc(self.gpa, .{
            .mcp_pid = c.getpid(),
            .helper_pid = self.pid,
            .client = self.client_name,
            .started_at_ms = self.presence_started_ms,
            .session = if (self.session) |ws| ws.created.name else "",
            .mux_socket = self.mux_sock orelse "",
            .label = std.mem.sliceTo(&self.browser_label, 0),
            .domain = domain,
        }, .{}) catch return;
        defer self.gpa.free(body);
        @import("../util/atomicwrite.zig").writeCacheFile(p, body, 0o600) catch {};
    }

    pub fn setBrowserLabel(self: *Engine, label: []const u8) void {
        @import("../web/webpresence.zig").copyText(&self.browser_label, label);
        self.writePresence();
    }

    /// Name the browser AND pin the identity the naming open asked for.
    pub fn setBrowserLabelFor(self: *Engine, label: []const u8, spec: ProfileSpec) void {
        var buf: [96]u8 = undefined;
        @import("../web/webpresence.zig").copyText(&self.label_identity, spec.describe(&buf));
        self.setBrowserLabel(label);
    }

    /// Whether an open naming the browser `name` in `spec` conflicts with
    /// the live browser. A browser with no tabs is free to be renamed: no
    /// caller is working in it.
    pub fn labelConflict(self: *const Engine, name: []const u8, spec: ProfileSpec) LabelConflict {
        if (self.views.items.len == 0) return .none;
        const label = std.mem.sliceTo(&self.browser_label, 0);
        if (label.len == 0) return .none;
        if (!std.mem.eql(u8, label, name)) return .{ .rename = label };
        const pinned = std.mem.sliceTo(&self.label_identity, 0);
        var buf: [96]u8 = undefined;
        if (pinned.len > 0 and !std.mem.eql(u8, pinned, spec.describe(&buf))) return .{ .identity = pinned };
        return .none;
    }

    fn removePresence(self: *Engine) void {
        if (self.owner != .self_spawned) return;
        self.presence_started_ms = 0;
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
        if (self.untrusted) self.stopUntrusted();
        self.dropConnection();
        if (self.pid > 0 and !self.untrusted) {
            var status: c_int = 0;
            if (c.waitpid(self.pid, &status, c.WNOHANG) == self.pid) self.diagnostic.exited(status);
            self.pid = -1;
        }
        self.clearViews();
        // Every published context died with the helper. Persistent ids
        // are safe in the store, so the next open republishes the SAME
        // id and lands in the SAME jar; ephemeral ones are simply gone.
        self.clearContexts();
        self.caps = .initEmpty();
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
        self.mode_selected = true;
        if (self.untrusted) return self.ensureUntrusted();
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
        // included.
        // A routed engine never takes this lane: the broker's engine is
        // the instance's DIRECT one (its own socket, no `--proxy`), so
        // adopting it for a route would browse direct under a route.
        if (self.remote != null and self.route_kind == .direct and brokerEngineWanted()) {
            if (self.brokerEngine(sock)) return true;
            // A diagnostic-capable broker accepted ownership of the launch.
            // Preserve its failure, and never race a second CEF process on its
            // profile root after a bind timeout. Unsupported brokers still fall
            // through to the compatibility lane below.
            if (self.broker_diagnostics and self.state == .unavailable) return false;
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

    fn ensureUntrusted(self: *Engine) bool {
        if (@import("builtin").os.tag != .linux or self.route_kind != .direct)
            return self.failStart("untrusted browsing requires Linux and route direct");
        if (self.state == .ready) return self.readAvailable() and self.state == .ready;
        // A connection that is not ready was already retired by `lost`;
        // this only releases what a failed start left behind.
        self.retireUntrusted(false);
        var parent_buf: [4096]u8 = undefined;
        const parent = untrustedParent(platform.runtimeDir(), &parent_buf) orelse
            return self.failStart("the per-user untrusted root directory (<runtime dir>/sketerm/untrusted) could not be created or is not private to this user; nothing was opened");
        // Reserve only a name: creation must happen in the cleanup owner,
        // or MCP death between mkdir and exec leaves an unowned root.
        var nonce: [UNTRUSTED_NAME_BYTES]u8 = undefined;
        if (c.getentropy(&nonce, nonce.len) != 0)
            return self.failStart("could not reserve the untrusted helper's private directory name");
        const hex = std.fmt.bytesToHex(nonce, .lower);
        if (parent.len + 1 + hex.len + "/t".len > UNTRUSTED_TMPDIR_MAX)
            return self.failStart("the runtime directory path is too long for an untrusted helper: its private TMPDIR would not fit Chromium's unix socket path; use a shorter XDG_RUNTIME_DIR. Nothing was opened");
        self.private_dir = std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ parent, hex }) catch
            return self.failStart("could not retain the untrusted helper's private directory name");
        self.untrusted_cleanup = .none;
        var ok = false;
        defer if (!ok) self.retireUntrusted(false);
        var bin_buf: [4096:0]u8 = undefined;
        const bin = findbin.find(&bin_buf) orelse return self.failStart(MISSING_MSG);
        var sock_z: [108:0]u8 = undefined;
        const sock = self.routePathZ(&sock_z, ".sock") orelse return self.failStart("untrusted helper socket path too long");
        var cache_z: [4096:0]u8 = undefined;
        _ = self.routePathZ(&cache_z, "-cache") orelse return self.failStart("untrusted helper cache path too long");
        if (!self.startHelper(bin, sock, &sock_z, &cache_z)) return false;
        if (!self.has(.untrusted_web)) {
            self.reason = "the dedicated helper did not verify capability untrusted-web; nothing was opened";
            self.state = .unavailable;
            return false;
        }
        ok = true;
        return true;
    }

    /// Retire the untrusted helper, letting it exit on its own first.
    fn stopUntrusted(self: *Engine) void {
        self.retireUntrusted(true);
    }

    /// Idempotent teardown of an untrusted helper under ONE deadline:
    /// self-exit (graceful only), then lifetime-fence close + SIGTERM so the
    /// owner kills its tree and deletes the root, then SIGKILL of the owner.
    /// This process never deletes the root itself; a root a killed owner
    /// left behind is swept by the next launch's supervisor.
    fn retireUntrusted(self: *Engine, graceful: bool) void {
        self.dropConnection();
        if (self.pid > 0) {
            const pidfd = pidfdOpen(self.pid);
            defer if (pidfd >= 0) {
                _ = c.close(pidfd);
            };
            const start = clock.nowMs();
            const graceful_end = start + (if (graceful) self.untrusted_grace_ms else 0);
            const deadline = graceful_end + self.untrusted_retire_ms;
            var status: c_int = 0;
            var outcome = self.awaitChild(pidfd, graceful_end, &status);
            if (outcome == .running) {
                self.closeLifetime();
                // Exact unreaped child only; wake a stopped cleanup owner.
                _ = c.kill(self.pid, c.SIGTERM);
                _ = c.kill(self.pid, c.SIGCONT);
                outcome = self.awaitChild(pidfd, deadline, &status);
            }
            if (outcome == .running) {
                std.debug.print("sketerm mcp: untrusted cleanup owner {d} missed its retirement deadline; killed it, its private root is left for the next launch's sweep\n", .{self.pid});
                _ = c.kill(self.pid, c.SIGKILL);
                outcome = while (true) {
                    const r = c.waitpid(self.pid, &status, 0);
                    if (r == self.pid) break .reaped;
                    if (r < 0 and std.posix.errno(r) != .INTR) break .lost;
                };
                if (outcome == .reaped) self.diagnostic.exited(status);
                self.untrusted_cleanup = .owner_killed;
            } else if (outcome == .reaped) {
                self.diagnostic.exited(status);
                // The owner exits only after its deletion attempt; dying by a
                // signal means it never reached it.
                self.untrusted_cleanup = if (!c.WIFEXITED(status))
                    .unknown
                else if (c.WEXITSTATUS(status) == SUPERVISOR_CLEANUP_FAILED)
                    .gave_up
                else
                    .deleted;
                if (self.untrusted_cleanup != .deleted) std.debug.print("sketerm mcp: untrusted cleanup owner did not delete its private root ({s}); the next launch's supervisor sweeps it\n", .{@tagName(self.untrusted_cleanup)});
            } else self.untrusted_cleanup = .unknown;
            self.pid = -1;
        }
        self.closeLifetime();
        if (self.private_dir) |dir| self.gpa.free(dir);
        self.private_dir = null;
        self.caps = .initEmpty();
        self.owner = .none;
        if (self.state == .ready) self.state = .idle;
    }

    fn closeLifetime(self: *Engine) void {
        if (self.private_lifetime >= 0) _ = c.close(self.private_lifetime);
        self.private_lifetime = -1;
    }

    const ChildWait = enum { reaped, running, lost };

    /// Wait for the spawned helper until `deadline`, draining its
    /// diagnostics; blocks on the pidfd when there is one.
    fn awaitChild(self: *Engine, pidfd: c_int, deadline: i64, status: *c_int) ChildWait {
        var diag_live = self.diagnostic.reader >= 0;
        while (true) {
            self.diagnostic.drain();
            const r = c.waitpid(self.pid, status, c.WNOHANG);
            if (r == self.pid) return .reaped;
            // Another reaper or a broken ownership invariant: nothing to wait on.
            if (r < 0 and std.posix.errno(r) != .INTR) return .lost;
            const left = deadline - clock.nowMs();
            if (left <= 0) return .running;
            var fds: [2]c.struct_pollfd = undefined;
            var n: usize = 0;
            if (pidfd >= 0) {
                fds[n] = .{ .fd = pidfd, .events = c.POLLIN, .revents = 0 };
                n += 1;
            }
            const diag_at = n;
            if (diag_live) {
                fds[n] = .{ .fd = self.diagnostic.reader, .events = c.POLLIN, .revents = 0 };
                n += 1;
            }
            const slice = if (pidfd >= 0) left else @min(left, CHILD_POLL_FALLBACK_MS);
            if (c.poll(&fds, @intCast(n), @intCast(slice)) > 0 and diag_live and
                fds[diag_at].revents & (c.POLLHUP | c.POLLERR | c.POLLNVAL) != 0) diag_live = false;
        }
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
        self.broker_diagnostics = info.diagnostics;
        // The broker's engine listens where every sibling expects it
        // (this instance dir); a different path would mean a confused
        // daemon and adopting it would bind views to the wrong root.
        if (!std.mem.eql(u8, info.sock, sock)) return false;
        const deadline = clock.nowMs() + SPAWN_WAIT_MS;
        const fd: c_int = while (true) {
            if (self.tryConnect(sock)) |fd| break fd;
            if (info.diagnostics) {
                if (self.remote.?.engineDiagnostic(arena_state.allocator())) |report| {
                    self.diagnostic.adoptReport(report);
                    if (report.exit_code != null or report.signal != null)
                        return self.failStart("the broker's browser helper exited before establishing its connection");
                } else |_| {}
            }
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
        if (self.untrusted) return false;
        if (self.route_kind != .direct) return false;
        if (!brokerEngineWanted()) return false;
        self.openStore();
        if (self.remote) |*r| return r.engineSupported();
        return false;
    }

    /// One spawn + connect + handshake attempt. On success the engine
    /// is `.ready` with the presence file written.
    fn startHelper(self: *Engine, bin: [*:0]const u8, sock: [:0]const u8, sock_z: *[108:0]u8, cache_z: *[4096:0]u8) bool {
        self.broker_diagnostics = false;
        // A stale socket from a crashed helper would make the connect
        // succeed against nothing.
        _ = c.unlink(sock.ptr);
        const env = self.sessionEnv();

        // The route's proxy, prepared BEFORE the fork (nothing may
        // allocate between fork and exec). A `via:` route binds its
        // SOCKS5 -> mux bridge here, so its port is in the argv.
        var proxy_z: [512:0]u8 = undefined;
        var proxy_buf: [512]u8 = undefined;
        const proxy_url = socksbridge.routeProxy(self.gpa, self.routeSpec(), &self.egress, mux_cli.muxConnect, &proxy_buf) catch
            return self.failStart("could not start this route's egress bridge (the via host's daemon is unreachable, or the loopback listener would not bind); nothing was opened directly instead");
        const proxy: ?[*:0]const u8 = if (proxy_url) |url|
            (std.fmt.bufPrintZ(&proxy_z, "{s}", .{url}) catch
                return self.failStart("the route's proxy url is too long")).ptr
        else
            null;

        self.diagnostic.deinit();
        self.diagnostic = diagnostic.Capture.init() catch
            return self.failStart("could not create the browser helper's diagnostic capture");
        var lifetime: [2]c_int = .{ -1, -1 };
        var lifetime_z: [16:0]u8 = undefined;
        var root_z: [4096:0]u8 = undefined;
        if (self.untrusted) {
            if (comptime @import("builtin").os.tag != .linux) return self.failStart("untrusted browsing requires Linux");
            const linux = std.os.linux;
            if (linux.errno(linux.pipe2(&lifetime, .{ .CLOEXEC = true })) != .SUCCESS)
                return self.failStart("could not create the untrusted supervisor's lifetime fence");
            _ = std.fmt.bufPrintZ(&lifetime_z, "{d}", .{lifetime[0]}) catch unreachable;
            _ = std.fmt.bufPrintZ(&root_z, "{s}", .{self.private_dir.?}) catch unreachable;
        }
        // Environment and argv are complete before the fork: the child
        // only rearranges descriptors and execs.
        var child_env = (if (self.untrusted)
            ChildEnv.build(self.gpa, &untrusted_env.dropped, &untrusted_env.sets)
        else if (env.active) blk: {
            // The session's display, software rendering. The exact env
            // recipe is display.zig's `run` (never derive wl-* paths; the
            // daemon returned these). The presenter flag arms THIS helper
            // as a client of a hub nobody else renders into, so its
            // toplevels are the watch-along surface and not a stray
            // desktop window.
            var sets: [9][2][]const u8 = undefined;
            var n: usize = 0;
            sets[n] = .{ "WAYLAND_DISPLAY", std.mem.sliceTo(&env.wl, 0) };
            n += 1;
            if (env.have_rt) {
                sets[n] = .{ "XDG_RUNTIME_DIR", std.mem.sliceTo(&env.rt, 0) };
                n += 1;
            }
            if (env.have_pulse) {
                sets[n] = .{ "PULSE_SERVER", std.mem.sliceTo(&env.pulse, 0) };
                n += 1;
            }
            for ([_][2][]const u8{
                .{ "XDG_SESSION_TYPE", "wayland" },
                .{ "LIBGL_ALWAYS_SOFTWARE", "1" },
                .{ "SKETERM_WEB_OZONE", "wayland" },
                .{ "SKETERM_WEB_GPU", "0" },
                .{ "SKETERM_WEB_SOFTWARE_WEBGL", "1" },
                .{ proto.PRESENTER_ENV, "1" },
            }) |kv| {
                sets[n] = kv;
                n += 1;
            }
            break :blk ChildEnv.build(self.gpa, &sessionDropped, sets[0..n]);
        } else ChildEnv.build(self.gpa, &keepAll, &.{
            .{ "SKETERM_WEB_GPU", "0" },
            .{ "SKETERM_WEB_OZONE", "headless" },
            .{ "SKETERM_WEB_SOFTWARE_WEBGL", "1" },
        })) catch {
            if (lifetime[0] >= 0) _ = c.close(lifetime[0]);
            if (lifetime[1] >= 0) _ = c.close(lifetime[1]);
            return self.failStart("could not prepare the browser helper's environment");
        };
        defer child_env.deinit();
        var argv: [12:null]?[*:0]const u8 = .{ bin, "--socket", sock_z, "--cache-dir", cache_z, null, null, null, null, null, null, null };
        if (self.untrusted) {
            argv[5] = "--untrusted";
            argv[6] = "--untrusted-root";
            argv[7] = &root_z;
            argv[8] = "--untrusted-lifetime-fd";
            argv[9] = &lifetime_z;
        }
        if (proxy) |p| {
            argv[5] = "--proxy";
            argv[6] = p;
        }
        const pid = c.fork();
        if (pid == 0) {
            if (self.untrusted) {
                // The supervisor must survive MCP death, not receive SIGKILL.
                // Only its read fence crosses either helper/preload exec.
                _ = c.close(lifetime[1]);
                if (!markCloexecFrom(3, .close_range)) c._exit(127);
                if (c.fcntl(lifetime[0], c.F_SETFD, @as(c_int, 0)) < 0) c._exit(127);
            }
            self.diagnostic.child();
            // stdin/stdout must not corrupt the MCP stream.
            const devnull = c.open("/dev/null", c.O_RDWR);
            if (devnull >= 0) {
                _ = c.dup2(devnull, 0);
                _ = c.dup2(devnull, 1);
                if (devnull > 2) _ = c.close(devnull);
            }
            _ = c.execve(bin, @ptrCast(@constCast(&argv)), @ptrCast(@constCast(child_env.envp)));
            diagnostic.Capture.execFailed();
            c._exit(127);
        }
        if (lifetime[0] >= 0) _ = c.close(lifetime[0]);
        if (pid < 0) {
            if (lifetime[1] >= 0) _ = c.close(lifetime[1]);
            self.diagnostic.deinit();
            return self.failStart("could not start the browser helper (fork failed)");
        }
        self.diagnostic.parent();
        self.pid = pid;
        if (self.untrusted) {
            self.private_lifetime = lifetime[1];
        }

        // Connect loop, watching for a helper that dies on startup
        // (missing libcef, bad CEF deployment) — that never binds.
        const deadline = clock.nowMs() + SPAWN_WAIT_MS;
        const fd: c_int = while (true) {
            self.diagnostic.drain();
            var status: c_int = 0;
            if (c.waitpid(self.pid, &status, c.WNOHANG) == self.pid) {
                self.diagnostic.exited(status);
                self.pid = -1;
                return self.failStart("the browser helper exited before establishing its connection");
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
        // A fresh helper tries its route again; only its own refusal
        // counts from here.
        if (self.route_refused) |r| self.gpa.free(r);
        self.route_refused = null;
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
        while (self.state == .ready and !self.has(.semantic) and !self.has(.frames_shm)) {
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

    /// Only failed starts kill: an untrusted helper there never served a
    /// page, so its owner is retired without the graceful self-exit wait.
    fn killChild(self: *Engine) void {
        if (self.untrusted) {
            self.retireUntrusted(false);
            return;
        }
        if (self.pid <= 0) return;
        _ = c.kill(self.pid, c.SIGKILL);
        var status: c_int = 0;
        if (c.waitpid(self.pid, &status, 0) == self.pid) self.diagnostic.exited(status);
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
        if (self.current != id and self.findView(id) != null) {
            self.current = id;
            self.writePresence();
        }
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
        return self.openViewWith(url, w, h, spec, policy_arg, null);
    }

    /// As `openViewIn`, optionally with a response-body CAPTURE, which
    /// is installed before the view's first request exactly like a
    /// policy, and refused (nothing opened) on a helper that cannot
    /// honour it.
    pub fn openViewWith(self: *Engine, url: []const u8, w: u16, h: u16, spec: ProfileSpec, policy_arg: ?*const NetPolicy, capture_arg: ?*const CaptureFilter) !*View {
        return self.openViewConfigured(url, w, h, spec, policy_arg, capture_arg, .{}, null);
    }

    pub fn openViewConfigured(self: *Engine, url: []const u8, w: u16, h: u16, spec: ProfileSpec, policy_arg: ?*const NetPolicy, capture_arg: ?*const CaptureFilter, emulation: Emulation, max_fps: ?u16) !*View {
        if (!emulation.valid()) return error.InvalidEmulation;
        const requested_fps: ?u16 = max_fps orelse self.default_max_fps;
        if (requested_fps) |fps| if (fps == 0 or fps > proto.MAX_VIEW_FPS) return error.InvalidFrameRate;
        var policy: ?*const NetPolicy = policy_arg;
        if (policy == null and spec == .named) policy = self.profile_policy.getPtr(spec.named);
        const wants_untrusted = if (policy) |p| p.untrusted else false;
        if (wants_untrusted) {
            if (policy.?.allow_schemes & ~netpolicy.default_schemes != 0) return error.UntrustedRestrictions;
            if (spec != .ephemeral or self.route_kind != .direct) return error.UntrustedRestrictions;
            if (@import("builtin").os.tag != .linux) return error.UntrustedUnsupported;
            // Mode is fixed at engine creation; an ordinary engine is never
            // flipped, whatever state it is in.
            if (!self.untrusted) return error.UntrustedModeConflict;
        } else if (self.untrusted) return error.UntrustedRestrictions;
        if (!self.ensure()) return error.Unavailable;
        errdefer if (self.untrusted and self.views.items.len == 0) self.stopUntrusted();
        if (wants_untrusted and !self.has(.untrusted_web)) return error.UntrustedUnsupported;
        if (emulation.present() and !self.has(.web_emulation)) return error.EmulationUnsupported;
        if (requested_fps != null and !self.has(.view_max_fps)) return error.FrameRateUnsupported;
        // A routed helper that refused its route says so right after
        // the handshake; read that before minting a view it would refuse.
        self.pumpOnce(0);
        if (self.state != .ready) return if (self.route_refused != null) error.RouteRefused else error.Unavailable;
        self.diagnostic.stage = .creating_browser;

        if (policy != null) {
            if (!self.has(.net_policy)) return error.PolicyUnsupported;
            if (wants_untrusted and !self.has(.net_policy_ack)) return error.PolicyAckUnsupported;
            // The helper can hold this many policies; past it a policied
            // view would silently run unpoliced, so refuse instead.
            if (self.views.items.len >= proto.MAX_POLICY_VIEWS) return error.PolicyTooManyViews;
        }
        if (capture_arg != null) {
            if (!self.has(.capture)) return error.CaptureUnsupported;
            // The capture lives in the same per-view helper slot a policy
            // does; past the table a captured view would silently record
            // nothing.
            if (self.views.items.len >= proto.MAX_POLICY_VIEWS) return error.CaptureTooManyViews;
        }

        var ctx_id: u32 = 0;
        var ctx_ephemeral = false;
        var profile_name: []const u8 = "";
        if (spec != .default) {
            // Both caps, or nothing: with CAP_CONTEXTS alone an old
            // helper resolves an unknown context through the SHARED jar
            // and never says so.
            if (!self.has(.contexts) or !self.has(.contexts_fail_closed)) return error.ContextsUnsupported;
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
        var owned_cap: ?CaptureFilter = if (capture_arg) |f| try dupeCapture(self.gpa, f.*) else null;
        errdefer if (owned_cap) |*f| freeCapture(self.gpa, f);
        const new_id = try nextViewId();
        const v = try self.gpa.create(View);
        var registered = false;
        v.* = .{
            .id = new_id,
            .w = w,
            .h = h,
            .emulation = emulation,
            .max_fps = if (self.has(.view_max_fps)) requested_fps orelse proto.DEFAULT_HEADLESS_FPS else null,
            .context = ctx_id,
            .ephemeral_ctx = ctx_ephemeral,
            .pol = owned_pol,
            .cap = owned_cap,
        };
        owned_pol = null;
        owned_cap = null;
        // A policy ACK may arrive before any browser exists, so register first.
        errdefer {
            if (self.state == .ready) self.send(proto.ViewDestroy{ .view = new_id }) catch {};
            if (!registered or self.findView(new_id) != null) self.abandonView(v);
        }
        if (profile_name.len > 0) v.profile = try self.gpa.dupe(u8, profile_name);
        try self.views.append(self.gpa, v);
        registered = true;
        if (emulation.present()) self.send(proto.ViewEmulation{
            .view = new_id,
            .color_scheme = if (emulation.color_scheme) |value| @intFromEnum(value) else 0,
            .reduced_motion = if (emulation.reduced_motion) |value| @intFromEnum(value) else 0,
            .scale_x1000 = if (emulation.device_scale_factor != null) emulation.scale() else 0,
        }) catch return error.Unavailable;
        if (policy) |p| {
            const serial = self.mintPolicySerial();
            v.pol_serial = serial;
            v.pol_wait_serial = if (self.has(.net_policy_ack)) serial else 0;
            self.send(policyFrame(new_id, serial, p)) catch return error.Unavailable;
            if (self.has(.net_policy_ack)) {
                const ev = try self.awaitPolicyReply(new_id, serial, SEND_TIMEOUT_MS);
                if (ev.active != 1) return error.PolicyRefused;
                applyPolicyAccounting(v, ev);
            } else v.pol_active = true;
            if (p.block_ads) |on| {
                self.send(proto.InterceptSet{ .view = new_id, .enabled = if (on) 1 else 0 }) catch return error.Unavailable;
            }
        }
        if (capture_arg) |f| {
            v.cap_serial = self.next_capture_serial;
            self.next_capture_serial += 1;
            self.send(captureInstallFrame(new_id, v.cap_serial, f)) catch return error.Unavailable;
        }
        if (url.len > 0 and self.has(.view_create_url)) {
            self.send(proto.ViewCreateUrl{
                .view = v.id,
                .w = w,
                .h = h,
                .scale_x1000 = emulation.scale(),
                .context = ctx_id,
                .url = url,
                .max_fps = v.max_fps orelse 0,
            }) catch return error.Unavailable;
        } else {
            self.send(proto.ViewCreate{
                .view = v.id,
                .w = w,
                .h = h,
                .scale_x1000 = emulation.scale(),
                .context = ctx_id,
                .max_fps = v.max_fps orelse 0,
            }) catch return error.Unavailable;
        }
        // A hidden view is never painted; headless views are always
        // "shown" — nothing else would ever show them.
        self.send(proto.ViewShow{ .view = v.id }) catch return error.Unavailable;
        if (url.len > 0 and !self.has(.view_create_url)) {
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
            .max_fps = if (opener) |o| o.max_fps else null,
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
                const id = proto.mintEphemeralCtx(&self.next_eph) orelse return error.StoreIo;
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

    fn captureInstallFrame(view_id: u32, serial: u32, f: *const CaptureFilter) proto.CaptureSet {
        return .{
            .view = view_id,
            .serial = serial,
            .op = @intFromEnum(proto.CaptureOp.install),
            .upto = 0,
            .types = f.types,
            .max_body = f.max_body,
            .max_total = f.max_total,
            .url_contains = f.url_contains,
            .url_regex = f.url_regex,
            .hosts = f.hosts,
            .methods = f.methods,
            .mime_prefixes = f.mime_prefixes,
        };
    }

    fn policyFrame(view_id: u32, serial: u32, p: *const NetPolicy) proto.NetPolicySet {
        return .{
            .view = view_id,
            .serial = serial,
            .flags = (if (p.allow_private) proto.NetPolicySet.flag_allow_private else @as(u32, 0)) |
                (if (p.untrusted) proto.NetPolicySet.flag_untrusted else @as(u32, 0)),
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
                const dead = self.live.orderedRemove(i);
                if (self.state == .ready) self.send(proto.ContextDestroy{ .id = id }) catch {};
                if (dead.name.len > 0) self.gpa.free(dead.name);
            }
            return;
        }
    }

    pub fn closeView(self: *Engine, id: u32) void {
        for (self.views.items, 0..) |v, i| {
            if (v.id != id) continue;
            if (self.state == .ready) self.send(proto.ViewDestroy{ .view = id }) catch {};
            // A failed send calls lost(), which already freed every view.
            if (self.findView(id) == null) return;
            const context = v.context;
            v.deinit(self.gpa);
            self.gpa.destroy(v);
            _ = self.views.orderedRemove(i);
            self.releaseContext(context);
            if (self.current == id)
                self.current = if (self.views.items.len > 0) self.views.items[self.views.items.len - 1].id else 0;
            self.writePresence();
            if (self.untrusted and self.views.items.len == 0) {
                self.stopUntrusted();
                self.state = .idle;
            }
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
        return self.has(.contexts) and self.has(.contexts_fail_closed);
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
    pub const SaveError = error{ Unsupported, Unavailable, Timeout };
    pub const Saved = enum { flushed, nothing_live };

    /// Commit every persistent jar of the running engine to disk NOW
    /// (every named profile's cookies, and the instance's own durable
    /// jar), without closing a view or stopping the engine: the
    /// "keep this login" save after a sign-in or a human hand-back.
    /// Rides the helper's `flush_req`, answered by `ev_flushed` once
    /// every jar's flush callback completed. Chromium commits a jar as
    /// one SQLite transaction, so a crash leaves the previous jar or
    /// the new one, never a half-written file. Site storage
    /// (localStorage/IndexedDB) keeps Chromium's own ~15s cadence; the
    /// engine's periodic flush (20s) and a clean exit still apply.
    /// With no engine running there is nothing live to lose: the store
    /// on disk is already the whole truth, and no engine is spawned
    /// just to answer.
    pub fn saveProfiles(self: *Engine, budget_ms: i64) SaveError!Saved {
        if (self.state != .ready) return .nothing_live;
        if (!self.has(.flush)) return error.Unsupported;
        const token = self.flush_token_next;
        self.flush_token_next +%= 1;
        if (self.flush_token_next == 0) self.flush_token_next = 1;
        self.send(proto.FlushReq{ .token = token }) catch return error.Unavailable;
        const deadline = clock.nowMs() + @max(budget_ms, 100);
        while (self.flushed_token != token) {
            if (self.state != .ready) return error.Unavailable;
            if (clock.nowMs() >= deadline) return error.Timeout;
            self.pumpOnce(40);
        }
        return .flushed;
    }

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
        if (p.untrusted or self.untrusted) return error.UntrustedRestrictions;
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
        tightened: [11][]const u8 = undefined,
        n_tightened: usize = 0,
        ignored: [11][]const u8 = undefined,
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
        if (!self.has(.net_policy_ack)) return error.PolicyAckUnsupported;
        if (incoming.untrusted) |want| {
            if (want != old.untrusted) return error.UntrustedModeConflict;
        }
        var report = TightenReport{};
        var next = try dupePolicy(self.gpa, old.*);
        errdefer freePolicy(self.gpa, &next);

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
        try self.tightenHosts(old.allow_top, incoming.allow_top, &next.allow_top, &report, "allow_hosts", next.allow_schemes);
        try self.tightenHosts(old.allow_sub, incoming.allow_sub, &next.allow_sub, &report, "allow_subresource_hosts", next.allow_schemes);
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
            } else {
                report.ign("block_ads");
            }
        }

        if (report.n_tightened == 0) {
            freePolicy(self.gpa, &next);
            return report;
        }
        const serial = self.mintPolicySerial();
        v.pol_reply = null;
        v.pol_wait_serial = serial;
        errdefer self.closeView(view_id);
        self.send(policyFrame(view_id, serial, &next)) catch return error.Unavailable;
        const ev = try self.awaitPolicyReply(view_id, serial, SEND_TIMEOUT_MS);
        if (ev.active != 1) return error.PolicyRefused;
        if (incoming.block_ads == true)
            self.send(proto.InterceptSet{ .view = view_id, .enabled = 1 }) catch return error.Unavailable;
        const live = self.findView(view_id) orelse return error.NoView;
        freePolicy(self.gpa, &live.pol.?);
        live.pol = next;
        live.pol_serial = serial;
        applyPolicyAccounting(live, ev);
        return report;
    }

    /// An omitted host list is untouched; a present one INTERSECTS (an
    /// explicit empty list narrows to no hosts), and any host it names
    /// beyond the old list is a loosening named under `name`.
    fn tightenHosts(self: *Engine, old: []const []const u8, incoming: ?[]const []const u8, out: *[]const []const u8, report: *TightenReport, name: []const u8, schemes: u16) !void {
        const want = incoming orelse return;
        var extra = false;
        for (want) |h| {
            var covered = false;
            for (old) |base| if (netpolicy.entrySubset(h, base, self.untrusted, schemes)) {
                covered = true;
                break;
            };
            if (!covered) extra = true;
        }
        if (extra) report.ign(name);
        const kept = try intersectHosts(self.gpa, old, want, self.untrusted, schemes);
        var changed = kept.len != old.len;
        if (!changed) for (old, kept) |a, b| {
            if (!std.mem.eql(u8, a, b)) changed = true;
        };
        if (changed) {
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

    /// Intersect host scopes and ports without widening either list.
    fn intersectHosts(gpa: std.mem.Allocator, old: []const []const u8, incoming: []const []const u8, untrusted: bool, schemes: u16) ![]const []const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |h| gpa.free(h);
            out.deinit(gpa);
        }
        for (old) |h| {
            for (incoming) |want| {
                const kept = if (netpolicy.entrySubset(h, want, untrusted, schemes)) h else if (netpolicy.entrySubset(want, h, untrusted, schemes)) want else continue;
                if (hostListed(out.items, kept)) continue;
                const owned = try gpa.dupe(u8, kept);
                out.append(gpa, owned) catch |err| {
                    gpa.free(owned);
                    return err;
                };
            }
        }
        return try out.toOwnedSlice(gpa);
    }

    fn mintPolicySerial(self: *Engine) u32 {
        const serial = self.next_policy_serial;
        self.next_policy_serial +%= 1;
        if (self.next_policy_serial == 0) self.next_policy_serial = 1;
        return serial;
    }

    fn awaitPolicyReply(self: *Engine, id: u32, serial: u32, budget_ms: i64) !proto.EvNetPolicy {
        defer if (self.findView(id)) |v| {
            v.pol_wait_serial = 0;
            v.pol_reply = null;
        };
        const deadline = clock.nowMs() + @max(budget_ms, 0);
        while (true) {
            if (self.state != .ready) return error.Unavailable;
            const v = self.findView(id) orelse return error.NoView;
            if (v.create_failed != null) return error.PolicyRefused;
            if (v.pol_reply) |ev| if (ev.serial == serial) return ev;
            const left = deadline - clock.nowMs();
            if (left <= 0) return error.PolicyAckTimeout;
            self.pumpOnce(@intCast(@min(left, 40)));
        }
    }

    fn applyPolicyAccounting(v: *View, ev: proto.EvNetPolicy) void {
        v.pol_active = ev.active == 1;
        v.pol_install_failed = v.pol != null and ev.active != 1;
        v.pol_exhausted = ev.exhausted;
        v.pol_requests = ev.requests;
        v.pol_bytes = ev.bytes;
        v.pol_navigations = ev.navigations;
        v.pol_ms_left = ev.ms_left;
        v.pol_denied = ev.denied;
    }

    /// Wait for this query's correlated accounting rather than an arbitrary
    /// pump turn. Read-only: a timeout or refusal is returned, the view is
    /// never closed. An abandoned query's serial is never waited on again
    /// and differs from the view's install serial, so its late reply is
    /// dropped by `dispatch` instead of answering a later query.
    pub fn netPolicyStatus(self: *Engine, id: u32, budget_ms: i64) !*View {
        if (!self.ensure()) return error.Unavailable;
        const v = self.findView(id) orelse return error.NoView;
        if (self.has(.net_policy)) {
            if (self.has(.net_policy_ack)) {
                const serial = self.mintPolicySerial();
                v.pol_wait_serial = serial;
                v.pol_reply = null;
                self.send(proto.NetPolicyReq{ .view = id, .serial = serial }) catch return error.Unavailable;
                const ev = try self.awaitPolicyReply(id, serial, budget_ms);
                const live = self.findView(id) orelse return error.NoView;
                applyPolicyAccounting(live, ev);
                if (live.pol != null and ev.active != 1) return error.PolicyRefused;
                return live;
            }
            // An older helper echoes no serial: any accounting frame for the
            // live policy that lands after the request answers it.
            const seen = v.pol_seen;
            self.send(proto.NetPolicyReq{ .view = id }) catch return error.Unavailable;
            const deadline = clock.nowMs() + @max(budget_ms, 0);
            while (true) {
                if (self.state != .ready) return error.Unavailable;
                const live = self.findView(id) orelse return error.NoView;
                if (live.pol_seen != seen) return live;
                const left = deadline - clock.nowMs();
                if (left <= 0) return error.PolicyAckTimeout;
                self.pumpOnce(@intCast(@min(left, 40)));
            }
        }
        return self.findView(id) orelse error.NoView;
    }

    pub fn navigate(self: *Engine, id: u32, url: []const u8) !void {
        if (!self.ensure()) return error.Unavailable;
        self.diagnostic.stage = .navigating;
        const v = self.findView(id) orelse return error.NoView;
        navfault.navigationRequested(self.gpa, &v.load_retry);
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
        if (action != .stop) navfault.navigationRequested(self.gpa, &v.load_retry);
        self.send(proto.NavAction{ .view = id, .action = @intFromEnum(action) }) catch return error.Unavailable;
        if (action == .stop) v.reader_guards.invalidate();
    }

    /// Wheel scroll through the ordinary input path, at the view
    /// centre (headless has no remembered pointer position).
    pub fn scroll(self: *Engine, id: u32, dx: i32, dy: i32) !void {
        if (!self.ensure()) return error.Unavailable;
        const v = self.findView(id) orelse return error.NoView;
        try self.sendInput(proto.InputScroll{ .view = id, .x = @intCast(v.w / 2), .y = @intCast(v.h / 2), .dx = dx, .dy = dy, .mods = 0 });
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
        try self.sendInput(proto.InputKey{ .view = id, .kind = @intFromEnum(proto.KeyKind.down), .keyval = keysym, .keycode = 0, .mods = mods, .text = text });
        try self.sendInput(proto.InputKey{ .view = id, .kind = @intFromEnum(proto.KeyKind.up), .keyval = keysym, .keycode = 0, .mods = mods, .text = "" });
    }

    /// One input frame (`InputPointer`, `InputScroll`, `InputKey`,
    /// `InputPaste`) through the ordinary path a GUI's own input rides,
    /// once the view has painted. Coordinates are logical viewport pixels.
    pub fn sendInput(self: *Engine, frame: anytype) !void {
        if (!self.ensure()) return error.Unavailable;
        if (self.findView(frame.view) == null) return error.NoView;
        // A bare IME commit inserts nothing in a windowless browser; text rides the clipboard path.
        if (@TypeOf(frame) == proto.InputPaste and !self.has(.clipboard)) return error.NoTextInput;
        self.awaitFirstPaint(frame.view, 5_000);
        self.send(frame) catch return error.Unavailable;
    }

    /// One painted frame of a view, as straight RGBA in its PIXEL size
    /// (`w`x`h`), beside the logical viewport input coordinates use.
    pub const Frame = struct { gen: u32, w: u16, h: u16, view_w: u16, view_h: u16, rgba: []u8 };

    /// The view's newest frame once its paint serial differs from
    /// `since` (what a previous answer named; 0 takes any painted
    /// frame), waiting at most `budget_ms` for a paint.
    ///
    /// AIDEV-NOTE: this is the PULLED frame source (the MCP backlog rule:
    /// never stream toward an MCP client). A watcher long-polls with the
    /// last serial it drew, so an idle page costs one answer per budget
    /// and a busy one at most one frame per call; the newest pixels win.
    /// @return null when no newer frame was painted within the budget
    pub fn frameAfter(self: *Engine, arena: std.mem.Allocator, view_id: u32, since: u32, budget_ms: i64) !?Frame {
        if (!self.ensure()) return error.Unavailable;
        if (self.findView(view_id) == null) return error.NoView;
        const deadline = clock.nowMs() + @max(budget_ms, 0);
        while (true) {
            const v = self.findView(view_id) orelse return error.NoView;
            if (v.buf_fd >= 0 and v.frame_gen != 0 and v.frame_gen != since) break;
            if (clock.nowMs() >= deadline) return null;
            if (self.state != .ready) return error.Unavailable;
            self.pumpOnce(20);
        }
        const v = self.findView(view_id) orelse return error.NoView;
        return .{
            .gen = v.frame_gen,
            .w = v.buf_w,
            .h = v.buf_h,
            .view_w = v.w,
            .view_h = v.h,
            .rgba = try frameRgba(arena, v),
        };
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
        self.send(proto.ViewResize{ .view = id, .w = w, .h = h, .scale_x1000 = v.emulation.scale() }) catch return error.Unavailable;
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
        if (!self.has(.downloads) or !self.has(.download_start)) return error.Unsupported;
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
            const chosen = download_policy.uniquePath(&path_buf, dir, safeLeaf(if (ev.name.len != 0) ev.name else "download"), 1000) orelse {
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
            pathz.makeParentDirs(d.path) catch {
                self.send(proto.DownloadDecide{ .view = ev.view, .id = ev.id, .path = "" }) catch {};
                d.failed = true;
                d.fail_reason = "the download path is too long";
                return;
            };
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
        if (!self.has(.intercept)) return error.NoIntercept;
        const v = self.findView(id) orelse return error.NoView;
        if (v.net_log) |old| {
            self.gpa.free(old);
            v.net_log = null;
        }
        v.net_log_waiting = true;
        // The reason-carrying lane when the helper has it; the legacy
        // frame otherwise. Both park the same JSON shape on the view.
        if (self.has(.net_policy)) {
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

    /// Set the view's CEF scheduler cap without changing stream transport or pacing.
    pub fn setMaxFps(self: *Engine, id: u32, fps: u16) !void {
        if (fps == 0 or fps > proto.MAX_VIEW_FPS) return error.InvalidFrameRate;
        if (!self.ensure()) return error.Unavailable;
        if (!self.has(.view_max_fps)) return error.FrameRateUnsupported;
        const v = self.findView(id) orelse return error.NoView;
        try self.send(proto.ViewMaxFps{ .view = id, .fps = fps });
        v.max_fps = fps;
    }

    /// Open a helper-owned socket without consuming any binary stream traffic.
    /// `codecs` non-null asks for an encoded stream (`vcodec.Codec` ids the
    /// consumer decodes, empty = lossless only); a helper without
    /// `stream-encoded` is asked for raw, and its reply says raw.
    pub fn openStream(self: *Engine, arena: std.mem.Allocator, id: u32, audio: bool, budget_ms: i64, max_fps: ?u16, codecs: ?[]const u8) !proto.EvStreamOpen {
        if (max_fps) |fps| if (fps == 0 or fps > proto.MAX_VIEW_FPS) return error.InvalidFrameRate;
        if (!self.ensure()) return error.Unavailable;
        if (!self.has(.web_stream)) return error.NoStream;
        if (max_fps != null and !self.has(.view_max_fps)) return error.FrameRateUnsupported;
        // A stream that ended is only known once its `ev_stream_closed` is read.
        self.pumpOnce(0);
        const v = self.findView(id) orelse return error.NoView;
        if (v.stream_request != 0) return error.StreamPending;
        if (v.streaming) return error.StreamActive;
        if (self.next_stream_request == std.math.maxInt(u32)) return error.RequestIdsExhausted;
        const req = self.next_stream_request;
        self.next_stream_request += 1;
        v.stream_request = req;
        defer if (self.findView(id)) |live| {
            live.stream_request = 0;
            if (live.stream_reply) |raw| self.gpa.free(raw);
            live.stream_reply = null;
        };
        // An uncertain open must not leave an unnamed stream slot behind.
        errdefer self.send(proto.StreamClose{ .view = id }) catch {};
        const encoded = codecs != null and self.has(.stream_encoded);
        self.send(proto.StreamOpen{
            .view = id,
            .req = req,
            .audio = @intFromBool(audio and self.has(.stream_audio)),
            .encoding = if (encoded) .encoded else .raw,
            .codecs = if (encoded) codecs.? else "",
        }) catch return error.Unavailable;
        const deadline = clock.nowMs() + @max(budget_ms, 1);
        while (clock.nowMs() < deadline) {
            const live = self.findView(id) orelse return error.NoView;
            if (live.stream_reply) |raw| {
                const reply = try proto.decode(proto.EvStreamOpen, try arena.dupe(u8, raw));
                if (reply.err.len == 0) {
                    const stream = @import("../web/stream.zig");
                    if (!live.streaming) return error.StreamEnded;
                    if (!stream.isToken(reply.token) or reply.path.len == 0 or reply.path[0] != '/' or
                        std.mem.indexOfScalar(u8, reply.path, 0) != null) return error.BadStreamReply;
                    if (max_fps) |fps| try self.setMaxFps(id, fps);
                } else if (reply.path.len != 0 or reply.token.len != 0) return error.BadStreamReply;
                return reply;
            }
            if (self.state != .ready) return error.Unavailable;
            self.pumpOnce(@intCast(@min(40, @max(0, deadline - clock.nowMs()))));
        }
        return error.Timeout;
    }

    // ---- response-body capture ---------------------------------------

    /// One metadata page of the view's finished exchanges (and, with
    /// `in_flight`, the unfinished ones after them). The entries and
    /// their strings live in `arena`.
    pub fn captureList(self: *Engine, arena: std.mem.Allocator, id: u32, since: u32, max: u16, in_flight: bool, budget_ms: i64) !proto.CaptureList {
        if (!self.ensure()) return error.Unavailable;
        const v = self.findView(id) orelse return error.NoView;
        if (v.cap == null) return error.NoCapture;
        if (v.cap_list) |old| {
            self.gpa.free(old);
            v.cap_list = null;
        }
        self.send(proto.CaptureListReq{
            .view = id,
            .since = since,
            .max = max,
            .flags = if (in_flight) proto.CaptureListReq.flag_in_flight else 0,
        }) catch return error.Unavailable;
        const deadline = clock.nowMs() + @max(budget_ms, 100);
        while (clock.nowMs() < deadline) {
            const vv = self.findView(id) orelse return error.NoView;
            if (vv.cap_list) |raw| {
                // Owned by the arena from here: the view's copy is
                // replaced by the next reply.
                const mine = try arena.dupe(u8, raw);
                return proto.CaptureList.decodeAlloc(mine, arena) catch error.Unavailable;
            }
            if (self.state != .ready) return error.Unavailable;
            self.pumpOnce(40);
        }
        return error.Timeout;
    }

    /// One chunk of one captured body. The reply must name the same
    /// exchange, part and offset; a late answer to an abandoned read is
    /// skipped rather than taken for this one. Strings live in `arena`.
    pub fn captureBody(self: *Engine, arena: std.mem.Allocator, id: u32, seq: u32, part: proto.CapturePart, offset: u64, max: u32, budget_ms: i64) !proto.CaptureBody {
        if (!self.ensure()) return error.Unavailable;
        const v = self.findView(id) orelse return error.NoView;
        if (v.cap == null) return error.NoCapture;
        if (v.cap_body) |old| {
            self.gpa.free(old);
            v.cap_body = null;
        }
        self.send(proto.CaptureBodyReq{ .view = id, .seq = seq, .part = @intFromEnum(part), .offset = offset, .max = max }) catch return error.Unavailable;
        const deadline = clock.nowMs() + @max(budget_ms, 100);
        while (clock.nowMs() < deadline) {
            const vv = self.findView(id) orelse return error.NoView;
            if (vv.cap_body) |raw| {
                const mine = try arena.dupe(u8, raw);
                self.gpa.free(raw);
                vv.cap_body = null;
                const b = proto.decode(proto.CaptureBody, mine) catch return error.Unavailable;
                if (b.seq == seq and b.part == @intFromEnum(part) and b.offset == offset) return b;
                continue;
            }
            if (self.state != .ready) return error.Unavailable;
            self.pumpOnce(40);
        }
        return error.Timeout;
    }

    /// Narrow a live view's capture: `clear` frees exchanges up to a
    /// cursor (0 = all), `disable` stops recording. There is no
    /// install here — a capture added to a live view would miss the
    /// requests that already ran, so it only ever rides the open.
    pub fn captureNarrow(self: *Engine, id: u32, op: proto.CaptureOp, upto: u32) !void {
        if (!self.ensure()) return error.Unavailable;
        const v = self.findView(id) orelse return error.NoView;
        if (v.cap == null) return error.NoCapture;
        std.debug.assert(op == .clear or op == .disable);
        self.send(proto.CaptureSet{
            .view = id,
            .serial = v.cap_serial,
            .op = @intFromEnum(op),
            .upto = upto,
            .types = 0,
            .max_body = 0,
            .max_total = 0,
            .url_contains = "",
            .url_regex = "",
            .hosts = &.{},
            .methods = &.{},
            .mime_prefixes = &.{},
        }) catch return error.Unavailable;
        if (op == .disable) v.cap_disabled = true;
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
        if (!self.has(.semantic)) return error.NoSemantic;
        if (self.findView(view_id) == null) return error.NoView;

        // `click`/`hover` are synthesized through the real input path,
        // which needs a composited frame to hit-test against.
        if (req.kind == .act) self.awaitFirstPaint(view_id, @min(budget_ms, 5_000));

        const ki = @intFromEnum(req.kind);
        const v = self.findView(view_id) orelse return error.NoView;
        if (!self.has(.semantic_request_ids) and v.legacy_quarantine.isHeld(ki))
            return error.LegacySemanticReplyPending;
        // Drop a stale parked reply from an earlier timed-out call of
        // the same kind: it answers an older question.
        if (v.inbox[ki]) |old| {
            self.gpa.free(old.text);
            v.inbox[ki] = null;
        }
        const request = if (self.has(.semantic_request_ids)) self.nextSemanticRequest() else 0;
        v.waiting[ki] = true;
        v.waiting_request[ki] = request;
        if (req.kind == .snapshot)
            v.want_full = req.mode == @intFromEnum(proto.SnapMode.full) or req.scope != 0;
        var timed_out = false;
        defer self.finishWait(view_id, ki, request, timed_out);

        const sent: anyerror!void = switch (req.kind) {
            .snapshot => self.sendSemantic(request, proto.SemSnapshotReq{ .view = view_id, .mode = req.mode, .detail = req.detail, .scope = req.scope }),
            .act => if (if (self.has(.reader_ids)) readerGuard(v, req.id) else null) |guard|
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
            .read => if (self.has(.reader_ids))
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

    /// PNG of the view's newest software frame. Briefly waits for a
    /// paint already on its way (the engine paces itself), but settles
    /// for the existing buffer — a static page repaints nothing, which is
    /// correct, not stale.
    pub fn screenshotPng(self: *Engine, arena: std.mem.Allocator, view_id: u32, budget_ms: i64) ![]u8 {
        if (!self.ensure()) return error.Unavailable;
        const v0 = self.findView(view_id) orelse return error.NoView;
        const gen0 = v0.frame_gen;
        const had_frame = v0.buf_fd >= 0;
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
        const rgba = try frameRgba(arena, v);
        return png.encodeRgba(arena, rgba, v.buf_w, v.buf_h);
    }

    /// The view's shm frame as straight opaque RGBA; the one reader of
    /// the frame buffer (`screenshotPng` and `frameAfter` share it).
    fn frameRgba(arena: std.mem.Allocator, v: *const View) ![]u8 {
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
        return png.shmToRgba(arena, pixels[0..size], v.buf_w, v.buf_h, v.buf_stride, @intFromEnum(png.ShmFormat.xrgb8888));
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
        self.diagnostic.drain();
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
            const n = c.recvmsg(self.fd, &mh, if (platform.is_linux) c.MSG_CMSG_CLOEXEC else 0);
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
                        if (!platform.is_linux and c.fcntl(passed, c.F_SETFD, c.FD_CLOEXEC) < 0) {
                            _ = c.close(passed);
                            continue;
                        }
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
            .ev_stream_open => {
                const ev = proto.decode(proto.EvStreamOpen, frame.payload) catch return;
                const v = self.findView(ev.view) orelse return;
                if (v.stream_request == 0 or ev.req != v.stream_request or v.stream_reply != null) return;
                if (ev.err.len == 0) v.streaming = true;
                self.setOwned(&v.stream_reply, frame.payload);
            },
            .ev_stream_closed => {
                const ev = proto.decode(proto.EvStreamClosed, frame.payload) catch return;
                if (self.findView(ev.view)) |v| v.streaming = false;
            },
            .hello_ack => {
                const ack = proto.HelloAck.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ack.caps);
                if (ack.proto != proto.PROTO_VERSION) {
                    self.lost();
                    self.reason = "the browser helper speaks a different protocol version";
                    return;
                }
                self.caps = proto.parseCaps(ack.caps);
                // Headless: allow real popups for the whole connection.
                // A cancelled popup makes window.open return null, which
                // is what breaks every federated sign-in at its last
                // step; there is no user here to protect from one.
                if (self.has(.popup_open)) {
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
                // MCP software compositing delivers no dma-bufs, so this should
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
            .ev_view_watchers => {
                const ev = proto.decode(proto.EvViewWatchers, frame.payload) catch return;
                if (self.findView(ev.view)) |v| {
                    v.watchers = ev.watchers;
                    v.controllers = ev.controllers;
                    v.watch_changed_ms = clock.nowMs();
                }
            },
            .ev_flushed => {
                const ev = proto.decode(proto.EvFlushed, frame.payload) catch return;
                self.flushed_token = ev.token;
            },
            .ev_page_popup => {
                const ev = proto.decode(proto.EvPagePopup, frame.payload) catch return;
                if (ev.state == proto.page_popup_opened) {
                    // A popup the helper really opened, opener intact.
                    // Adopting it is what makes an OAuth flow work
                    // headlessly at all: it is the window the identity
                    // provider posts its result back through.
                    // Showing it is also the CLAIM: the helper closes a
                    // popup no client frame has named within its adopt
                    // timeout, which killed every sign-in popup after 8s
                    // while a human typed into it through the presenter.
                    self.adoptPopupView(ev) catch {
                        self.send(proto.ViewDestroy{ .view = ev.popup_view }) catch {};
                        return;
                    };
                    self.send(proto.ViewShow{ .view = ev.popup_view }) catch {};
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
                    if (ev.url.len > 0 and !std.mem.eql(u8, v.url orelse "", ev.url)) {
                        self.setOwned(&v.url, ev.url);
                        if (self.current == ev.view) self.writePresence();
                    }
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
            .ev_load_retry => {
                const ev = proto.decode(proto.EvLoadRetry, frame.payload) catch return;
                if (self.findView(ev.view)) |v| {
                    if (v.load_retry) |*old| old.free(self.gpa);
                    v.load_retry = navfault.LoadErrRec.initRetry(self.gpa, ev) catch null;
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
                    if (!accept) {
                        // Refusal fails this TLS load before the engine's later error arrives.
                        if (v.load_error) |*old| old.free(self.gpa);
                        v.load_error = navfault.LoadErrRec.init(self.gpa, .{
                            .view = ev.view,
                            .code = ev.code,
                            .url = ev.url,
                            .msg = ev.msg,
                        }) catch null;
                    }
                    self.send(proto.CertDecision{ .view = ev.view, .proceed = if (accept) 1 else 0 }) catch {};
                }
            },
            .ev_route_refused => {
                // Fail closed: the helper will open nothing, so let it go
                // and say why; the next call starts a fresh one, which
                // tries the route again.
                const ev = proto.decode(proto.EvRouteRefused, frame.payload) catch return;
                self.setOwned(&self.route_refused, ev.reason);
                self.lost();
                self.reason = self.route_refused orelse LOST_MSG;
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
                defer ev.freeDecoded(self.gpa);
                const v = self.findView(ev.view) orelse return;
                v.net_next_seq = ev.next_seq;
                const json = proto.netLogJson(self.gpa, ev) catch return;
                if (v.net_log) |old| self.gpa.free(old);
                v.net_log = json;
                v.net_log_waiting = false;
            },
            .net_log => {
                const ev = proto.NetLog.decodeAlloc(frame.payload, self.gpa) catch return;
                defer ev.freeDecoded(self.gpa);
                const v = self.findView(ev.view) orelse return;
                v.net_next_seq = ev.next_seq;
                const json = proto.netLogJson2(self.gpa, ev) catch return;
                if (v.net_log) |old| self.gpa.free(old);
                v.net_log = json;
                v.net_log_waiting = false;
            },
            .capture_list => {
                const ev = proto.CaptureList.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ev.entries);
                const v = self.findView(ev.view) orelse return;
                // The unsolicited refusal of OUR install: the open must
                // fail closed rather than run uncaptured.
                if (ev.state == @intFromEnum(proto.CaptureState.refused) and v.cap_serial != 0 and ev.serial == v.cap_serial)
                    v.cap_install_failed = true;
                const copy = self.gpa.dupe(u8, frame.payload) catch return;
                if (v.cap_list) |old| self.gpa.free(old);
                v.cap_list = copy;
            },
            .capture_body => {
                const ev = proto.decode(proto.CaptureBody, frame.payload) catch return;
                const v = self.findView(ev.view) orelse return;
                const copy = self.gpa.dupe(u8, frame.payload) catch return;
                if (v.cap_body) |old| self.gpa.free(old);
                v.cap_body = copy;
            },
            .ev_net_policy => {
                const ev = proto.decode(proto.EvNetPolicy, frame.payload) catch return;
                const v = self.findView(ev.view) orelse return;
                if (v.pol_wait_serial != 0 and ev.serial == v.pol_wait_serial) {
                    v.pol_reply = ev;
                    return;
                }
                // A stale serial answers for a policy this view no
                // longer runs; ignore it.
                if (ev.serial != v.pol_serial) return;
                v.pol_seen +%= 1;
                applyPolicyAccounting(v, ev);
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

test "presence updates and teardown leave broker and adopted owner records intact" {
    const gpa = std.testing.allocator;
    var template = "/tmp/sk-presence-owner-XXXXXX".* ++ [_]u8{0};
    const dir = std.mem.span(c.mkdtemp(&template) orelse return error.SkipZigTest);
    defer _ = c.rmdir(dir.ptr);
    var path_buf: [512:0]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/web.json", .{dir});
    defer _ = c.unlink(path.ptr);
    const original = "{\"broker_pid\":42,\"helper_pid\":43,\"session\":\"web-owner\",\"label\":\"Owner login\"}";
    try @import("../util/atomicwrite.zig").writeCacheFile(path, original, 0o600);
    for ([_]Owner{ .broker, .adopted }) |owner| {
        var eng = try Engine.init(gpa, dir, null, null, .{});
        eng.state = .ready;
        eng.owner = owner;
        eng.setBrowserLabel("Sibling login");
        eng.writePresence();
        eng.lost();
        eng.deinit();
        const f = c.fopen(path.ptr, "r") orelse return error.TestUnexpectedResult;
        defer _ = c.fclose(f);
        var bytes: [512]u8 = undefined;
        const n = c.fread(&bytes, 1, bytes.len, f);
        try std.testing.expectEqualStrings(original, bytes[0..n]);
    }
    // The spawning client still publishes and refreshes its own label.
    var eng = try Engine.init(gpa, dir, null, null, .{});
    defer eng.deinit();
    eng.state = .ready;
    eng.owner = .self_spawned;
    eng.setBrowserLabel("Login \"café\"");
    var mux_buf: [512]u8 = undefined;
    const metadata = @import("../web/webpresence.zig").readMetadata(gpa, try std.fmt.bufPrint(&mux_buf, "{s}/mux.sock", .{dir}), "");
    try std.testing.expectEqualStrings("Login \"café\"", metadata.title());
}

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

test "a suggested download name is a leaf" {
    try std.testing.expectEqualStrings("f.bin", Engine.safeLeaf("f.bin"));
    // A path in the engine's suggested name must never escape the
    // download directory.
    try std.testing.expectEqualStrings("passwd", Engine.safeLeaf("../../etc/passwd"));
    try std.testing.expectEqualStrings("download", Engine.safeLeaf(".."));
    try std.testing.expectEqualStrings("download", Engine.safeLeaf(""));
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
        self.eng.caps.setPresent(.semantic, true);
        self.eng.caps.setPresent(.view_create_url, true);
        self.eng.caps.setPresent(.contexts, contexts);
        self.eng.caps.setPresent(.contexts_fail_closed, fail_closed);
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

    fn policyAck(self: *Pair, v: *const View) !void {
        self.eng.caps.insert(.net_policy_ack);
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(std.testing.allocator);
        try proto.encode(std.testing.allocator, &buf, proto.EvNetPolicy{
            .view = v.id,
            .serial = self.eng.next_policy_serial,
            .active = 1,
            .exhausted = v.pol_exhausted,
            .requests = v.pol_requests,
            .bytes = v.pol_bytes,
            .navigations = v.pol_navigations,
            .ms_left = v.pol_ms_left,
            .denied = v.pol_denied,
        });
        try std.testing.expectEqual(@as(isize, @intCast(buf.items.len)), c.write(self.peer, buf.items.ptr, buf.items.len));
    }

    fn openPolicyAck(self: *Pair, pol: *const NetPolicy) !*View {
        self.eng.caps.insert(.net_policy_ack);
        var helper = PolicyPeer{ .peer = self.peer, .serial = self.eng.next_policy_serial };
        const thread = try std.Thread.spawn(.{}, PolicyPeer.run, .{&helper});
        defer thread.join();
        return self.eng.openViewIn("https://site.example/", 800, 600, if (pol.untrusted) .ephemeral else .default, pol);
    }
};

const StreamPeer = struct {
    peer: c_int,
    audio: u8 = 0,
    err: []const u8 = "",
    /// What the open asked for, and the raw payload length it arrived in.
    encoding: proto.StreamEncoding = .raw,
    codecs: [4]u8 = @splat(0),
    payload_len: usize = 0,

    fn run(self: *StreamPeer) void {
        var buf: [4096]u8 = undefined;
        const deadline = clock.nowMs() + 2000;
        while (clock.nowMs() < deadline) {
            const n = c.recv(self.peer, &buf, buf.len, c.MSG_PEEK | c.MSG_DONTWAIT);
            if (n > 0) {
                var reader = proto.Reader.init(buf[0..@intCast(n)]);
                while (reader.next() catch null) |f| {
                    if (f.tag != .stream_open) continue;
                    const req = proto.decode(proto.StreamOpen, f.payload) catch return;
                    self.audio = req.audio;
                    self.encoding = req.encoding;
                    self.payload_len = f.payload.len;
                    @memcpy(self.codecs[0..@min(4, req.codecs.len)], req.codecs[0..@min(4, req.codecs.len)]);
                    var out: std.ArrayList(u8) = .empty;
                    defer out.deinit(std.heap.page_allocator);
                    // A stale success must not satisfy this request.
                    proto.encode(std.heap.page_allocator, &out, proto.EvStreamOpen{
                        .view = req.view, .req = req.req - 1, .path = "/tmp/stale.sock",
                        .token = "00000000000000000000000000000000", .err = "",
                    }) catch return;
                    proto.encode(std.heap.page_allocator, &out, proto.EvStreamClosed{ .view = req.view, .reason = "previous stream ended" }) catch return;
                    proto.encode(std.heap.page_allocator, &out, proto.EvStreamOpen{
                        .view = req.view, .req = req.req,
                        .path = if (self.err.len == 0) "/tmp/current.sock" else "",
                        .token = if (self.err.len == 0) "0123456789abcdef0123456789abcdef" else "",
                        .err = self.err,
                        .audio = req.audio,
                        .encoding = req.encoding,
                        .codec = if (req.codecs.len != 0) req.codecs[0] else 0,
                    }) catch return;
                    _ = c.write(self.peer, out.items.ptr, out.items.len);
                    return;
                }
            }
            _ = c.usleep(1000);
        }
    }
};

test "stream opens correlate replies, negotiate audio, and refuse a second stream without asking" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    const v = try gpa.create(View);
    v.* = .{ .id = 1, .w = 800, .h = 600 };
    try pair.eng.views.append(gpa, v);
    pair.eng.caps.insert(.web_stream);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    for ([_]bool{ false, true }) |has_audio| {
        pair.eng.caps.setPresent(.stream_audio, has_audio);
        var peer = StreamPeer{ .peer = pair.peer };
        const reply = blk: {
            const thread = try std.Thread.spawn(.{}, StreamPeer.run, .{&peer});
            defer thread.join();
            break :blk try pair.eng.openStream(arena_state.allocator(), 1, true, 1000, null, null);
        };
        try std.testing.expectEqualStrings("/tmp/current.sock", reply.path);
        try std.testing.expectEqual(@as(u8, @intFromBool(has_audio)), peer.audio);
        try std.testing.expectEqual(@as(u8, @intFromBool(has_audio)), reply.audio);
        try std.testing.expectEqual(@as(u32, 0), v.stream_request);
        try std.testing.expect(v.stream_reply == null);
        var buf: [4096]u8 = undefined;
        var reader = proto.Reader.init(pair.drain(&buf));
        try std.testing.expectEqual(proto.Tag.stream_open, (try reader.next()).?.tag);
        try std.testing.expect((try reader.next()) == null);
        // While it lives a second open is a conflict, decided here: nothing is sent.
        try std.testing.expectError(error.StreamActive, pair.eng.openStream(arena_state.allocator(), 1, true, 10, null, null));
        try std.testing.expectEqual(@as(usize, 0), pair.drain(&buf).len);
        // Its end frees the view for the next open.
        var closed: std.ArrayList(u8) = .empty;
        defer closed.deinit(gpa);
        try proto.encodePayload(gpa, &closed, proto.EvStreamClosed{ .view = 1, .reason = "the stream client disconnected" });
        pair.eng.dispatch(.{ .tag = .ev_stream_closed, .payload = closed.items });
    }
    // A refusal the helper decided is handed back as such, and cancels nothing.
    var peer = StreamPeer{ .peer = pair.peer, .err = "too many open streams" };
    const reply = blk: {
        const thread = try std.Thread.spawn(.{}, StreamPeer.run, .{&peer});
        defer thread.join();
        break :blk try pair.eng.openStream(arena_state.allocator(), 1, false, 1000, null, null);
    };
    try std.testing.expectEqualStrings(peer.err, reply.err);
    var buf: [4096]u8 = undefined;
    var reader = proto.Reader.init(pair.drain(&buf));
    try std.testing.expectEqual(proto.Tag.stream_open, (try reader.next()).?.tag);
    try std.testing.expect((try reader.next()) == null);
}

test "an encoded stream is asked for only from a helper that streams encoded, and a raw open stays V1" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    const v = try gpa.create(View);
    v.* = .{ .id = 1, .w = 800, .h = 600 };
    try pair.eng.views.append(gpa, v);
    pair.eng.caps.insert(.web_stream);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const Case = struct { cap: bool, codecs: ?[]const u8, want: proto.StreamEncoding, len: usize };
    for ([_]Case{
        // An older helper: the request goes out as the 9-byte V1 open.
        .{ .cap = false, .codecs = &.{1}, .want = .raw, .len = 9 },
        .{ .cap = true, .codecs = &.{ 1, 2 }, .want = .encoded, .len = 9 + 1 + 2 + 2 },
        .{ .cap = true, .codecs = &.{}, .want = .encoded, .len = 9 + 1 + 2 },
        // A raw request is byte-identical to V1 even on a capable helper.
        .{ .cap = true, .codecs = null, .want = .raw, .len = 9 },
    }) |case| {
        pair.eng.caps.setPresent(.stream_encoded, case.cap);
        var peer = StreamPeer{ .peer = pair.peer };
        const reply = blk: {
            const thread = try std.Thread.spawn(.{}, StreamPeer.run, .{&peer});
            defer thread.join();
            break :blk try pair.eng.openStream(arena_state.allocator(), 1, false, 1000, null, case.codecs);
        };
        try std.testing.expectEqual(case.want, peer.encoding);
        try std.testing.expectEqual(case.len, peer.payload_len);
        try std.testing.expectEqual(case.want, reply.encoding);
        if (case.want == .encoded and case.codecs.?.len != 0) try std.testing.expectEqual(case.codecs.?[0], reply.codec);
        var buf: [4096]u8 = undefined;
        _ = pair.drain(&buf);
        var closed: std.ArrayList(u8) = .empty;
        defer closed.deinit(gpa);
        try proto.encodePayload(gpa, &closed, proto.EvStreamClosed{ .view = 1, .reason = "the stream client disconnected" });
        pair.eng.dispatch(.{ .tag = .ev_stream_closed, .payload = closed.items });
    }
}

test "frame rates are per-view, pre-create, bounded and fail closed on unsupported helpers" {
    const t = std.testing;
    var pair = try Pair.init(t.allocator);
    defer pair.deinit();
    var buf: [4096]u8 = undefined;
    try t.expectError(error.FrameRateUnsupported, pair.eng.openViewConfigured("about:blank", 800, 600, .default, null, null, .{}, 15));
    try t.expectEqual(@as(usize, 0), pair.drain(&buf).len);
    pair.eng.default_max_fps = 30;
    try t.expectError(error.FrameRateUnsupported, pair.eng.openView("about:blank", 800, 600));
    pair.eng.caps.insert(.view_max_fps);
    const view = try pair.eng.openView("about:blank", 800, 600);
    var reader = proto.Reader.init(pair.drain(&buf));
    const create = try proto.decode(proto.ViewCreateUrl, (try reader.next()).?.payload);
    try t.expectEqual(@as(u16, 30), create.max_fps);
    try t.expectEqual(@as(u16, 30), view.max_fps.?);
    try t.expectError(error.InvalidFrameRate, pair.eng.setMaxFps(view.id, 0));
    try t.expectError(error.InvalidFrameRate, pair.eng.setMaxFps(view.id, proto.MAX_VIEW_FPS + 1));
    try pair.eng.setMaxFps(view.id, 15);
    reader = proto.Reader.init(pair.drain(&buf));
    try t.expectEqual(@as(u16, 15), (try proto.decode(proto.ViewMaxFps, (try reader.next()).?.payload)).fps);
    try t.expectEqual(@as(u16, 15), view.max_fps.?);
    pair.eng.caps.insert(.web_stream);
    pair.eng.caps.remove(.view_max_fps);
    try t.expectError(error.FrameRateUnsupported, pair.eng.openStream(t.allocator, view.id, false, 10, 60, null));
    try t.expectEqual(@as(usize, 0), pair.drain(&buf).len);
}

test "stream timeout cancels the slot and late replies cannot satisfy another open" {
    const gpa = std.testing.allocator;
    var pair = try Pair.init(gpa);
    defer pair.deinit();
    const v = try gpa.create(View);
    v.* = .{ .id = 1, .w = 800, .h = 600 };
    try pair.eng.views.append(gpa, v);
    try std.testing.expectError(error.NoStream, pair.eng.openStream(gpa, 1, true, 10, null, null));
    pair.eng.caps.insert(.web_stream);
    try std.testing.expectError(error.Timeout, pair.eng.openStream(gpa, 1, true, 10, null, null));
    try std.testing.expectEqual(@as(u32, 0), v.stream_request);
    var buf: [4096]u8 = undefined;
    var reader = proto.Reader.init(pair.drain(&buf));
    const req = try proto.decode(proto.StreamOpen, (try reader.next()).?.payload);
    try std.testing.expectEqual(proto.Tag.stream_close, (try reader.next()).?.tag);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try proto.encodePayload(gpa, &payload, proto.EvStreamOpen{
        .view = 1, .req = req.req, .path = "/tmp/late.sock",
        .token = "00000000000000000000000000000000", .err = "",
    });
    pair.eng.dispatch(.{ .tag = .ev_stream_open, .payload = payload.items });
    try std.testing.expect(v.stream_reply == null);
}

const PolicyPeer = struct {
    const Action = enum { success, reject, timeout, disappear, create_failed };
    peer: c_int,
    serial: u32,
    tag: proto.Tag = .net_policy_set,
    action: Action = .success,
    reply: ?proto.EvNetPolicy = null,
    before_ack_create: bool = false,
    answered: bool = false,

    fn run(self: *PolicyPeer) void {
        var buf: [65536]u8 = undefined;
        const deadline = clock.nowMs() + 2000;
        while (clock.nowMs() < deadline) {
            const n = c.recv(self.peer, &buf, buf.len, c.MSG_PEEK | c.MSG_DONTWAIT);
            if (n <= 0) {
                _ = c.usleep(1000);
                continue;
            }
            var reader = proto.Reader.init(buf[0..@intCast(n)]);
            while (reader.next() catch null) |frame| {
                if (frame.tag != self.tag) continue;
                var view: u32 = 0;
                var serial: u32 = 0;
                if (self.tag == .net_policy_set) {
                    const set = proto.NetPolicySet.decodeAlloc(frame.payload, std.heap.page_allocator) catch return;
                    defer std.heap.page_allocator.free(set.allow_top);
                    defer std.heap.page_allocator.free(set.allow_sub);
                    view = set.view;
                    serial = set.serial;
                } else {
                    const req = proto.decode(proto.NetPolicyReq, frame.payload) catch return;
                    view = req.view;
                    serial = req.serial;
                }
                if (serial != self.serial) continue;
                var ev = self.reply orelse proto.EvNetPolicy{
                    .view = view,
                    .serial = serial,
                    .active = 1,
                    .exhausted = 0,
                    .requests = 0,
                    .bytes = 0,
                    .navigations = 0,
                    .ms_left = 0,
                    .denied = @splat(0),
                };
                ev.view = view;
                ev.serial = serial + 1000;
                self.post(ev);
                _ = c.usleep(80_000);
                const waiting = c.recv(self.peer, &buf, buf.len, c.MSG_PEEK | c.MSG_DONTWAIT);
                if (waiting > 0) {
                    var pending = proto.Reader.init(buf[0..@intCast(waiting)]);
                    while (pending.next() catch null) |f| {
                        if (f.tag == .view_create or f.tag == .view_create_url) self.before_ack_create = true;
                    }
                }
                switch (self.action) {
                    .timeout => return,
                    .disappear => {
                        _ = c.shutdown(self.peer, c.SHUT_RDWR);
                        return;
                    },
                    .create_failed => self.post(proto.EvViewCreateFailed{ .view = view, .context = 0, .reason = "view disappeared" }),
                    .success, .reject => {
                        ev.serial = serial;
                        ev.active = if (self.action == .success) 1 else 0;
                        if (ev.active == 0) ev.exhausted = @intFromEnum(proto.NetReason.policy_refused);
                        self.post(ev);
                    },
                }
                self.answered = true;
                return;
            }
            _ = c.usleep(1000);
        }
    }

    fn post(self: *PolicyPeer, value: anytype) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(std.heap.page_allocator);
        proto.encode(std.heap.page_allocator, &buf, value) catch return;
        _ = c.write(self.peer, buf.items.ptr, buf.items.len);
    }
};

test "received frame descriptors cannot cross a later helper exec" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    const source = c.open("/dev/null", c.O_RDONLY | c.O_CLOEXEC);
    try std.testing.expect(source >= 0);
    defer _ = c.close(source);
    // A partial frame holds the descriptor in the receive queue rather
    // than dispatching it, covering the inheritance window before pairing.
    try @import("../smoke/unixsock.zig").sendWithFd(pair.peer, &.{0}, source);
    try std.testing.expect(pair.eng.readAvailable());
    try std.testing.expectEqual(@as(usize, 1), pair.eng.rx_fds.items.len);
    try std.testing.expect(c.fcntl(pair.eng.rx_fds.items[0], c.F_GETFD) & c.FD_CLOEXEC != 0);
}

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
    p.eng.caps.setPresent(.contexts, false);
    p.eng.caps.setPresent(.contexts_fail_closed, false);
    try std.testing.expectError(error.ContextsUnsupported, p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "work" }, null));
    try std.testing.expectError(error.ContextsUnsupported, p.eng.openViewIn("https://x.test/", 800, 600, .ephemeral, null));

    // CAP_CONTEXTS alone is WORSE than none: such a helper resolves an
    // unknown context through the shared jar and never says so.
    p.eng.caps.setPresent(.contexts, true);
    try std.testing.expectError(error.ContextsUnsupported, p.eng.openViewIn("https://x.test/", 800, 600, .{ .named = "work" }, null));

    // Fail closed means exactly this: no view, and not one byte on the
    // wire — the requested page never touched the shared cookie jar.
    try std.testing.expectEqual(@as(usize, 0), p.eng.views.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);

    // An invalid name is refused on its own, after the caps pass.
    p.eng.caps.setPresent(.contexts_fail_closed, true);
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

test "an adopted page popup is claimed with view_show so the helper keeps it past its adopt timeout" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    var buf: [8192]u8 = undefined;

    const opener = try p.eng.openViewIn("https://claude.test/login", 800, 600, .default, null);
    _ = p.drain(&buf);
    const popup_id: u32 = proto.ENGINE_VIEW_BASE + 1;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try proto.encodePayload(gpa, &payload, proto.EvPagePopup{
        .owner_view = opener.id,
        .popup_view = popup_id,
        .state = proto.page_popup_opened,
        .disposition = 0,
        .user_gesture = 1,
        .chromeless = 1,
        .w = 500,
        .h = 600,
        .url = "https://accounts.test/signin",
        .frame_name = "",
    });
    p.eng.dispatch(.{ .tag = .ev_page_popup, .payload = payload.items });
    try std.testing.expect(p.eng.findView(popup_id) != null);
    // The helper destroys a popup no client frame names within 8s, and
    // a human typing into it through the presenter names nothing.
    const shown = frameOf(proto.ViewShow, p.drain(&buf)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(popup_id, shown.view);

    // A repeated announcement re-claims; it does not adopt twice.
    p.eng.dispatch(.{ .tag = .ev_page_popup, .payload = payload.items });
    var count: usize = 0;
    for (p.eng.views.items) |v| {
        if (v.id == popup_id) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

/// The first frame of tag `tag` in `bytes`, decoded.
fn frameOf(comptime T: type, bytes: []const u8) ?T {
    var reader = proto.Reader.init(bytes);
    while ((reader.next() catch null)) |frame| {
        if (frame.tag == T.tag) return proto.decode(T, frame.payload) catch null;
    }
    return null;
}

test "ev_load_retry is kept through the retried load's start and cleared by the next navigation request" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    var buf: [8192]u8 = undefined;

    const v = try p.eng.openViewIn("https://a.test/", 800, 600, .default, null);
    _ = p.drain(&buf);
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    try proto.encodePayload(gpa, &payload, proto.EvLoadRetry{
        .view = v.id,
        .code = -21,
        .url = "https://a.test/",
        .msg = "ERR_NETWORK_CHANGED",
    });
    p.eng.dispatch(.{ .tag = .ev_load_retry, .payload = payload.items });
    try std.testing.expectEqual(@as(i32, -21), v.load_retry.?.code);
    try std.testing.expectEqualStrings("ERR_NETWORK_CHANGED", v.load_retry.?.msg);
    // No failure was reported: the helper healed it.
    try std.testing.expect(v.load_error == null);

    // The retried load starts and finishes; the record stays, because
    // this is the load the caller is still waiting on.
    payload.clearRetainingCapacity();
    try proto.encodePayload(gpa, &payload, proto.EvLoad{
        .view = v.id,
        .state = @intFromEnum(proto.LoadState.started),
        .url = "https://a.test/",
    });
    p.eng.dispatch(.{ .tag = .ev_load, .payload = payload.items });
    try std.testing.expect(v.load_retry != null);

    // A second retry event replaces the first rather than leaking it.
    payload.clearRetainingCapacity();
    try proto.encodePayload(gpa, &payload, proto.EvLoadRetry{
        .view = v.id,
        .code = -21,
        .url = "https://a.test/next",
        .msg = "ERR_NETWORK_CHANGED",
    });
    p.eng.dispatch(.{ .tag = .ev_load_retry, .payload = payload.items });
    try std.testing.expectEqualStrings("https://a.test/next", v.load_retry.?.url);

    // The client's own navigation is what retires it; a stop is not a
    // navigation.
    try p.eng.navAction(v.id, .stop);
    try std.testing.expect(v.load_retry != null);
    try p.eng.navigate(v.id, "https://b.test/");
    try std.testing.expect(v.load_retry == null);
    _ = p.drain(&buf);
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
    // No later load-error event or pump may be needed to report the refusal.
    try std.testing.expect(v.load_error != null);
    try std.testing.expectEqual(@as(i32, -202), v.load_error.?.code);
    try std.testing.expectEqualStrings("https://10.0.0.1/", v.load_error.?.url);
    try std.testing.expectEqualStrings("CERT_AUTHORITY_INVALID", v.load_error.?.msg);
    const refused = frameOf(proto.CertDecision, p.drain(&buf)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(v.id, refused.view);
    try std.testing.expectEqual(@as(u8, 0), refused.proceed);

    // A later engine-specific error replaces the immediate TLS failure.
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
    try std.testing.expectEqualStrings("ERR_CERT_AUTHORITY_INVALID", v.load_error.?.msg);

    // Opting in names ONE certificate, case-insensitively; a string
    // that cannot be a fingerprint is refused at the call.
    try std.testing.expectError(error.InvalidFingerprint, p.eng.setAcceptCert(v.id, "abc"));
    try p.eng.setAcceptCert(v.id, "AB" ** 32);
    p.eng.loadStarted(v, "https://10.0.0.1/");
    try std.testing.expect(v.cert == null and v.load_error == null);
    p.eng.dispatch(.{ .tag = .ev_cert_error, .payload = payload.items });
    try std.testing.expect(v.cert.?.verdict == .accepted);
    try std.testing.expect(v.load_error == null);
    const accepted = frameOf(proto.CertDecision, p.drain(&buf)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(v.id, accepted.view);
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
    try std.testing.expectEqual(@as(i32, -201), v.load_error.?.code);
    try std.testing.expectEqualStrings("https://other.test/", v.load_error.?.url);
    try std.testing.expectEqualStrings("CERT_DATE_INVALID", v.load_error.?.msg);
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
    p.eng.caps.setPresent(.contexts_fail_closed, false);
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
    try std.testing.expect(!p.eng.has(.net_policy));
    try std.testing.expectError(error.PolicyUnsupported, p.eng.openViewIn("https://site.example/", 800, 600, .default, &pol));
    // Fail closed: no view, and not one byte on the wire — the page was
    // never loaded unpoliced.
    try std.testing.expectEqual(@as(usize, 0), p.eng.views.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);
}

test "initial policy ACK precedes browser creation and delayed stale replies cannot satisfy it" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    pair.eng.caps.insert(.net_policy);
    pair.eng.caps.insert(.net_policy_ack);
    var helper = PolicyPeer{ .peer = pair.peer, .serial = pair.eng.next_policy_serial };
    const thread = try std.Thread.spawn(.{}, PolicyPeer.run, .{&helper});
    const started = clock.nowMs();
    const view = pair.eng.openViewIn("https://site.example/", 800, 600, .default, &.{ .allow_top = &.{"site.example"} }) catch |err| {
        thread.join();
        return err;
    };
    thread.join();
    try std.testing.expect(helper.answered);
    try std.testing.expect(!helper.before_ack_create);
    try std.testing.expect(clock.nowMs() - started >= 70);
    try std.testing.expect(view.pol_active);
    try std.testing.expectEqual(helper.serial, view.pol_serial);
}

test "rejected lost and missing initial policy ACKs never create an unpoliced browser" {
    for ([_]PolicyPeer.Action{ .reject, .timeout, .disappear, .create_failed }) |action| {
        var pair = try Pair.init(std.testing.allocator);
        defer pair.deinit();
        pair.eng.caps.insert(.net_policy);
        pair.eng.caps.insert(.net_policy_ack);
        var helper = PolicyPeer{ .peer = pair.peer, .serial = pair.eng.next_policy_serial, .action = action };
        const thread = try std.Thread.spawn(.{}, PolicyPeer.run, .{&helper});
        const opened = pair.eng.openViewIn("https://site.example/", 800, 600, .default, &.{ .allow_top = &.{"site.example"} });
        thread.join();
        try std.testing.expectError(switch (action) {
            .reject, .create_failed => error.PolicyRefused,
            .timeout => error.PolicyAckTimeout,
            .disappear => error.Unavailable,
            else => unreachable,
        }, opened);
        try std.testing.expectEqual(@as(usize, 0), pair.eng.views.items.len);
        try std.testing.expect(!helper.before_ack_create);
        var buf: [16384]u8 = undefined;
        var reader = proto.Reader.init(pair.drain(&buf));
        while (try reader.next()) |frame| {
            try std.testing.expect(frame.tag != .view_create and frame.tag != .view_create_url and frame.tag != .navigate);
        }
    }
}

test "live policy updates require ACK support and preserve accounting after the matching ACK" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    pair.eng.caps.insert(.net_policy);
    const view = try pair.eng.openViewIn("https://site.example/", 800, 600, .default, &.{ .allow_top = &.{"site.example"}, .max_requests = 100 });
    const id = view.id;
    const old_serial = view.pol_serial;
    var buf: [16384]u8 = undefined;
    _ = pair.drain(&buf);
    try std.testing.expectError(error.PolicyAckUnsupported, pair.eng.tightenViewPolicy(id, &.{ .max_requests = 10 }));
    try std.testing.expectEqual(@as(usize, 0), pair.drain(&buf).len);
    try std.testing.expectEqual(@as(u32, 100), view.pol.?.max_requests);
    pair.eng.caps.insert(.net_policy_ack);
    var helper = PolicyPeer{ .peer = pair.peer, .serial = pair.eng.next_policy_serial, .reply = .{
        .view = id,
        .serial = 0,
        .active = 1,
        .exhausted = @intFromEnum(proto.NetReason.byte_cap),
        .requests = 7,
        .bytes = 1234,
        .navigations = 2,
        .ms_left = 320,
        .denied = @splat(0),
    } };
    const thread = try std.Thread.spawn(.{}, PolicyPeer.run, .{&helper});
    const report = pair.eng.tightenViewPolicy(id, &.{ .max_requests = 10 });
    thread.join();
    try std.testing.expectEqual(@as(usize, 1), (try report).n_tightened);
    try std.testing.expectEqual(@as(u32, 10), view.pol.?.max_requests);
    try std.testing.expect(view.pol_serial != old_serial);
    try std.testing.expectEqual(@as(u32, 7), view.pol_requests);
    try std.testing.expectEqual(@as(u64, 1234), view.pol_bytes);
    try std.testing.expectEqual(@as(u32, 320), view.pol_ms_left);
    var stale = helper.reply.?;
    stale.serial = old_serial;
    stale.requests = 0;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(std.testing.allocator);
    try proto.encodePayload(std.testing.allocator, &payload, stale);
    pair.eng.dispatch(.{ .tag = .ev_net_policy, .payload = payload.items });
    try std.testing.expectEqual(@as(u32, 7), view.pol_requests);
}

test "rejected missing and disappearing update ACKs close only the affected view" {
    for ([_]PolicyPeer.Action{ .reject, .timeout, .disappear, .create_failed }) |action| {
        var pair = try Pair.init(std.testing.allocator);
        defer pair.deinit();
        pair.eng.caps.insert(.net_policy);
        const view = try pair.eng.openViewIn("https://site.example/", 800, 600, .default, &.{ .allow_top = &.{"site.example"}, .max_requests = 100 });
        const id = view.id;
        const other = try pair.eng.openView("https://other.example/", 800, 600);
        const other_id = other.id;
        var buf: [16384]u8 = undefined;
        _ = pair.drain(&buf);
        pair.eng.caps.insert(.net_policy_ack);
        var helper = PolicyPeer{ .peer = pair.peer, .serial = pair.eng.next_policy_serial, .action = action };
        const thread = try std.Thread.spawn(.{}, PolicyPeer.run, .{&helper});
        const updated = pair.eng.tightenViewPolicy(id, &.{ .max_requests = 10 });
        thread.join();
        try std.testing.expectError(switch (action) {
            .reject, .create_failed => error.PolicyRefused,
            .timeout => error.PolicyAckTimeout,
            .disappear => error.Unavailable,
            else => unreachable,
        }, updated);
        try std.testing.expect(pair.eng.findView(id) == null);
        if (action != .disappear) try std.testing.expect(pair.eng.findView(other_id) != null);
    }
}

test "policy status awaits a fresh query serial despite stale pushed accounting" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    pair.eng.caps.insert(.net_policy);
    const view = try pair.eng.openViewIn("https://site.example/", 800, 600, .default, &.{ .allow_top = &.{"site.example"} });
    const serial = view.pol_serial;
    var buf: [16384]u8 = undefined;
    _ = pair.drain(&buf);
    pair.eng.caps.insert(.net_policy_ack);
    var helper = PolicyPeer{ .peer = pair.peer, .serial = pair.eng.next_policy_serial, .tag = .net_policy_req, .reply = .{
        .view = view.id,
        .serial = 0,
        .active = 1,
        .exhausted = 0,
        .requests = 9,
        .bytes = 81,
        .navigations = 1,
        .ms_left = 10,
        .denied = @splat(0),
    } };
    const thread = try std.Thread.spawn(.{}, PolicyPeer.run, .{&helper});
    const started = clock.nowMs();
    const queried = pair.eng.netPolicyStatus(view.id, 500);
    thread.join();
    const fresh = try queried;
    try std.testing.expect(clock.nowMs() - started >= 70);
    try std.testing.expectEqual(@as(u32, 9), fresh.pol_requests);
    try std.testing.expectEqual(serial, fresh.pol_serial);
    _ = pair.drain(&buf);
    // A status query that times out is read-only: the view stays.
    const abandoned = pair.eng.next_policy_serial;
    try std.testing.expectError(error.PolicyAckTimeout, pair.eng.netPolicyStatus(fresh.id, 5));
    try std.testing.expectEqual(@as(usize, 1), pair.eng.views.items.len);
    try std.testing.expect(pair.eng.findView(fresh.id) != null);
    _ = pair.drain(&buf);
    // Its late reply arrives while the NEXT query waits: it must neither
    // answer that query nor be applied as accounting.
    var late: std.ArrayList(u8) = .empty;
    defer late.deinit(std.testing.allocator);
    try proto.encode(std.testing.allocator, &late, proto.EvNetPolicy{
        .view = fresh.id,
        .serial = abandoned,
        .active = 1,
        .exhausted = 0,
        .requests = 77,
        .bytes = 0,
        .navigations = 0,
        .ms_left = 0,
        .denied = @splat(0),
    });
    try std.testing.expectEqual(@as(isize, @intCast(late.items.len)), c.write(pair.peer, late.items.ptr, late.items.len));
    var next = PolicyPeer{ .peer = pair.peer, .serial = pair.eng.next_policy_serial, .tag = .net_policy_req, .reply = .{
        .view = fresh.id,
        .serial = 0,
        .active = 1,
        .exhausted = 0,
        .requests = 12,
        .bytes = 0,
        .navigations = 1,
        .ms_left = 0,
        .denied = @splat(0),
    } };
    const second = try std.Thread.spawn(.{}, PolicyPeer.run, .{&next});
    const requeried = pair.eng.netPolicyStatus(fresh.id, 1000);
    second.join();
    try std.testing.expectEqual(@as(u32, 12), (try requeried).pol_requests);
    try std.testing.expectEqual(serial, fresh.pol_serial);
}

test "an older helper's missing status reply leaves the view open" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    pair.eng.caps.insert(.net_policy);
    const view = try pair.eng.openViewIn("https://site.example/", 800, 600, .default, &.{ .allow_top = &.{"site.example"} });
    try std.testing.expectError(error.PolicyAckTimeout, pair.eng.netPolicyStatus(view.id, 5));
    try std.testing.expect(pair.eng.findView(view.id) != null);
    try std.testing.expectEqual(State.ready, pair.eng.state);
}

test "untrusted host intersection uses the narrowed schemes before testing explicit ports" {
    for ([_]netpolicy.Scheme{ .https, .http }) |scheme| {
        var pair = try Pair.init(std.testing.allocator);
        defer pair.deinit();
        pair.eng.caps.insert(.net_policy);
        const view = try pair.eng.openViewIn("https://site.example/", 800, 600, .default, &.{ .allow_top = &.{"site.example"} });
        pair.eng.untrusted = true;
        view.pol.?.untrusted = true;
        try pair.policyAck(view);
        const report = try pair.eng.tightenViewPolicy(view.id, &.{ .allow_schemes = scheme.bit(), .allow_top = &.{"site.example:443"} });
        try std.testing.expectEqual(scheme.bit(), view.pol.?.allow_schemes);
        if (scheme == .https) {
            try std.testing.expectEqual(@as(usize, 0), report.n_ignored);
            try std.testing.expectEqualStrings("site.example:443", view.pol.?.allow_top[0]);
        } else {
            try std.testing.expectEqual(@as(usize, 1), report.n_ignored);
            try std.testing.expectEqual(@as(usize, 0), view.pol.?.allow_top.len);
        }
    }
}

test "net_policy_set travels strictly before view_create_url, naming the same view" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.caps.setPresent(.net_policy, true);
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

test "a captured open is refused, opening nothing, without the capture capability" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    var buf: [8192]u8 = undefined;

    const f = CaptureFilter{ .mime_prefixes = &.{"application/json"} };
    try std.testing.expect(!p.eng.has(.capture));
    try std.testing.expectError(error.CaptureUnsupported, p.eng.openViewWith("https://site.example/", 800, 600, .default, null, &f));
    // Fail closed: no view, and not one byte on the wire — the page was
    // never loaded uncaptured.
    try std.testing.expectEqual(@as(usize, 0), p.eng.views.items.len);
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);
}

test "capture_set travels strictly before view_create_url, carrying the whole filter" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.caps.setPresent(.capture, true);
    var buf: [16384]u8 = undefined;

    const f = CaptureFilter{
        .hosts = &.{"spotify.com"},
        .methods = &.{"POST"},
        .mime_prefixes = &.{"application/json"},
        .url_contains = "/pathfinder/",
        .url_regex = "operationName=fetch",
        .max_body = 1 << 20,
        .max_total = 1 << 24,
    };
    const v = try p.eng.openViewWith("https://open.spotify.com/playlist/x", 800, 600, .default, null, &f);
    try std.testing.expect(v.cap != null);
    try std.testing.expect(v.cap_serial != 0);

    const bytes = p.drain(&buf);
    var reader = proto.Reader.init(bytes);
    const f1 = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.capture_set, f1.tag);
    const set = try proto.CaptureSet.decodeAlloc(f1.payload, gpa);
    defer set.freeLists(gpa);
    try std.testing.expectEqual(v.id, set.view);
    try std.testing.expectEqual(v.cap_serial, set.serial);
    try std.testing.expectEqual(proto.CaptureOp.install, @as(proto.CaptureOp, @enumFromInt(set.op)));
    try std.testing.expectEqual(capture.DEFAULT_TYPES, set.types);
    try std.testing.expectEqualStrings("spotify.com", set.hosts[0]);
    try std.testing.expectEqualStrings("POST", set.methods[0]);
    try std.testing.expectEqualStrings("operationName=fetch", set.url_regex);
    try std.testing.expectEqual(@as(u64, 1 << 24), set.max_total);
    const f2 = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.view_create_url, f2.tag);
    try std.testing.expectEqual(v.id, (try proto.decode(proto.ViewCreateUrl, f2.payload)).view);
}

test "a refused capture install for OUR serial fails the open; another serial does not" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.caps.setPresent(.capture, true);
    var buf: [16384]u8 = undefined;
    const f = CaptureFilter{};
    const v = try p.eng.openViewWith("https://site.example/", 800, 600, .default, null, &f);
    _ = p.drain(&buf);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    const refused = proto.CaptureList{
        .view = v.id,
        .serial = v.cap_serial + 7,
        .state = @intFromEnum(proto.CaptureState.refused),
        .more = 0,
        .max_body = 0,
        .max_total = 0,
        .stored = 0,
        .in_flight = 0,
        .next_cursor = 0,
        .head_cursor = 0,
        .dropped = @splat(0),
        .entries = &.{},
    };
    try proto.encodePayload(gpa, &payload, refused);
    p.eng.dispatch(.{ .tag = .capture_list, .payload = payload.items });
    try std.testing.expect(!v.cap_install_failed);

    payload.clearRetainingCapacity();
    var ours = refused;
    ours.serial = v.cap_serial;
    try proto.encodePayload(gpa, &payload, ours);
    p.eng.dispatch(.{ .tag = .capture_list, .payload = payload.items });
    try std.testing.expect(v.cap_install_failed);
}

test "captureBody skips a late answer for another offset and takes the matching one" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.caps.setPresent(.capture, true);
    var buf: [16384]u8 = undefined;
    const f = CaptureFilter{};
    const v = try p.eng.openViewWith("https://site.example/", 800, 600, .default, null, &f);
    _ = p.drain(&buf);

    var frames: std.ArrayList(u8) = .empty;
    defer frames.deinit(gpa);
    const reply = proto.CaptureBody{
        .view = v.id,
        .seq = 9,
        .part = 0,
        .found = 1,
        .complete = 1,
        .trunc = 0,
        .total = 10,
        .seen = 10,
        .offset = 4,
        .status = 200,
        .mime = "application/json",
        .charset = "",
        .headers = .{ .s = "" },
        .data = .{ .s = "STALE" },
    };
    try proto.encode(gpa, &frames, reply);
    var right = reply;
    right.offset = 0;
    right.data = .{ .s = "0123456789" };
    try proto.encode(gpa, &frames, right);
    // Both arrive AFTER the request goes out, as a helper's would:
    // anything already queued is drained by `ensure` before the send.
    const writer = try std.Thread.spawn(.{}, struct {
        fn run(fd: c_int, bytes: []const u8) void {
            var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 100 * std.time.ns_per_ms };
            _ = c.nanosleep(&ts, null);
            _ = c.write(fd, bytes.ptr, bytes.len);
        }
    }.run, .{ p.peer, frames.items });
    defer writer.join();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const got = try p.eng.captureBody(arena_state.allocator(), v.id, 9, .response, 0, 64, 2000);
    try std.testing.expectEqualStrings("0123456789", got.data.s);
    try std.testing.expectEqual(@as(u64, 0), got.offset);
}

test "capture verbs on a view without a capture say so, and disable is remembered" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.caps.setPresent(.capture, true);
    var buf: [16384]u8 = undefined;
    const plain = try p.eng.openViewWith("https://site.example/", 800, 600, .default, null, null);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    try std.testing.expectError(error.NoCapture, p.eng.captureList(arena_state.allocator(), plain.id, 0, 10, false, 100));
    try std.testing.expectError(error.NoCapture, p.eng.captureNarrow(plain.id, .clear, 0));

    const f = CaptureFilter{};
    const v = try p.eng.openViewWith("https://site.example/", 800, 600, .default, null, &f);
    _ = p.drain(&buf);
    try p.eng.captureNarrow(v.id, .disable, 0);
    try std.testing.expect(v.cap_disabled);
    var reader = proto.Reader.init(p.drain(&buf));
    const frame = (try reader.next()).?;
    try std.testing.expectEqual(proto.Tag.capture_set, frame.tag);
    const set = try proto.CaptureSet.decodeAlloc(frame.payload, gpa);
    defer set.freeLists(gpa);
    try std.testing.expectEqual(proto.CaptureOp.disable, @as(proto.CaptureOp, @enumFromInt(set.op)));
}

test "ev_net_policy: a stale serial is ignored, the live one updates, active=0 fails the install" {
    const gpa = std.testing.allocator;
    var p = try Pair.init(gpa);
    defer p.deinit();
    p.eng.caps.setPresent(.net_policy, true);
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
    p.eng.caps.setPresent(.net_policy, true);
    var buf: [16384]u8 = undefined;

    const pol = NetPolicy{
        .allow_top = &.{ "site.example", "cdn.example" },
        .max_requests = 100,
        .max_bytes = 1000,
    };
    const v = try p.eng.openViewIn("https://site.example/", 800, 600, .default, &pol);
    _ = p.drain(&buf);
    const first_serial = v.pol_serial;
    p.eng.caps.insert(.net_policy_ack);

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
    try p.policyAck(v);
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
    p.eng.caps.setPresent(.net_policy, true);
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
    try p.policyAck(v);
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
    p.eng.caps.setPresent(.net_policy, true);
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
    try p.policyAck(v);
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
        .untrusted = true,
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
    p.eng.caps.setPresent(.net_policy, true);
    var buf: [16384]u8 = undefined;

    const pol = NetPolicy{
        .allow_top = &.{ "site.example", "cdn.example" },
        .allow_sub = &.{"static.example"},
        .block_types = netpolicy.typeBit("image").?,
    };
    const v = try p.eng.openViewIn("https://site.example/", 800, 600, .default, &pol);
    _ = p.drain(&buf);

    // Absent lists and an explicit empty block_types move nothing.
    p.eng.caps.insert(.net_policy_ack);
    const r0 = try p.eng.tightenViewPolicy(v.id, &.{ .block_types = 0 });
    try std.testing.expectEqual(@as(usize, 0), r0.n_tightened);
    try std.testing.expectEqual(@as(usize, 0), r0.n_ignored);
    try std.testing.expectEqual(@as(usize, 2), v.pol.?.allow_top.len);
    try std.testing.expectEqual(@as(usize, 1), v.pol.?.allow_sub.len);
    try std.testing.expectEqual(@as(usize, 0), p.drain(&buf).len);

    // An explicit empty top-level list is the literal tighten: no hosts.
    // The subresource list was not said and survives.
    try p.policyAck(v);
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
    p.eng.caps.setPresent(.net_policy, true);
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

test "emulation capability refuses before publication and precedes the first document" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    const emulation = Emulation{ .color_scheme = .dark, .reduced_motion = .reduce, .device_scale_factor = 1.5 };
    var buf: [16384]u8 = undefined;
    try std.testing.expectError(error.EmulationUnsupported, pair.eng.openViewConfigured("https://site.example/", 800, 600, .ephemeral, null, null, emulation, null));
    try std.testing.expectEqual(@as(usize, 0), pair.drain(&buf).len);
    pair.eng.caps.insert(.web_emulation);
    pair.eng.caps.insert(.net_policy);
    const policy = NetPolicy{ .allow_top = &.{"site.example"} };
    const view = try pair.eng.openViewConfigured("https://site.example/", 800, 600, .ephemeral, &policy, null, emulation, null);
    var tags: [8]proto.Tag = undefined;
    try std.testing.expectEqualSlices(proto.Tag, &.{ .context_create, .view_emulation, .net_policy_set, .view_create_url, .view_show }, tagsOf(pair.drain(&buf), &tags));
    try pair.eng.resize(view.id, 900, 700);
    var reader = proto.Reader.init(pair.drain(&buf));
    const resized = try proto.decode(proto.ViewResize, (try reader.next()).?.payload);
    try std.testing.expectEqual(@as(u16, 1500), resized.scale_x1000);
}

test "untrusted opens never switch an ordinary helper or loosen a live policy" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    const policy = NetPolicy{ .untrusted = true, .allow_top = &.{"site.example:443"} };
    var buf: [16384]u8 = undefined;
    try std.testing.expectError(error.UntrustedRestrictions, pair.eng.openViewIn("https://site.example/", 800, 600, .default, &policy));
    try std.testing.expectError(error.UntrustedModeConflict, pair.eng.openViewIn("https://site.example/", 800, 600, .ephemeral, &policy));
    try std.testing.expectEqual(@as(usize, 0), pair.drain(&buf).len);
    pair.eng.untrusted = true;
    try std.testing.expectError(error.UntrustedUnsupported, pair.eng.openViewIn("https://site.example/", 800, 600, .ephemeral, &policy));
    try std.testing.expectEqual(State.idle, pair.eng.state);
    // Reconnect the fake peer after the refused open's cleanup.
    pair.reconnect();
    pair.eng.caps.insert(.untrusted_web);
    pair.eng.caps.insert(.net_policy);
    try std.testing.expectError(error.PolicyAckUnsupported, pair.eng.openViewIn("https://site.example/", 800, 600, .ephemeral, &policy));
    pair.reconnect();
    pair.eng.caps.insert(.untrusted_web);
    pair.eng.caps.insert(.net_policy);
    const view = try pair.openPolicyAck(&policy);
    try std.testing.expectError(error.UntrustedRestrictions, pair.eng.openView("https://site.example/", 800, 600));
    try std.testing.expectError(error.UntrustedModeConflict, pair.eng.tightenViewPolicy(view.id, &.{ .untrusted = false }));
    var reader = proto.Reader.init(pair.drain(&buf));
    _ = try reader.next(); // context_create
    const set = try proto.NetPolicySet.decodeAlloc((try reader.next()).?.payload, std.testing.allocator);
    defer std.testing.allocator.free(set.allow_top);
    defer std.testing.allocator.free(set.allow_sub);
    try std.testing.expectEqual(proto.NetPolicySet.flag_untrusted, set.flags);
    pair.eng.closeView(view.id);
    try std.testing.expectEqual(@as(c_int, -1), pair.eng.fd);
    try std.testing.expectEqual(State.idle, pair.eng.state);
}

/// Sets one environment variable for a test and restores it.
const EnvPin = struct {
    name: [*:0]const u8,
    saved: ?[:0]u8 = null,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvPin {
        var pin = EnvPin{ .name = name };
        if (c.getenv(name)) |old| pin.saved = try std.testing.allocator.dupeZ(u8, std.mem.span(@as([*:0]const u8, @ptrCast(old))));
        if (value) |v| _ = c.setenv(name, v, 1) else _ = c.unsetenv(name);
        return pin;
    }

    fn restore(self: *EnvPin) void {
        if (self.saved) |old| {
            _ = c.setenv(self.name, old.ptr, 1);
            std.testing.allocator.free(old);
        } else _ = c.unsetenv(self.name);
    }
};

test "a leftover private root never blocks the next untrusted launch and is never deleted here" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    var runtime = try EnvPin.set("XDG_RUNTIME_DIR", @ptrCast(&pair.tmpl));
    defer runtime.restore();
    var bin = try EnvPin.set("SKETERM_WEB_BIN", "/nonexistent/sketerm-webengine");
    defer bin.restore();
    pair.eng.untrusted = true;
    var parent_buf: [4096]u8 = undefined;
    const parent = untrustedParent(pair.stateDir(), &parent_buf) orelse return error.TestUnexpectedResult;
    // A dead supervisor's root, still holding a profile.
    var leftover: [512:0]u8 = undefined;
    _ = try std.fmt.bufPrintZ(&leftover, "{s}/{s}", .{ parent, "0123456789abcdef" });
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(&leftover, 0o700));
    pair.eng.private_dir = try std.testing.allocator.dupe(u8, std.mem.span(@as([*:0]const u8, &leftover)));
    pair.eng.stopUntrusted();
    try std.testing.expect(pair.eng.private_dir == null);
    try std.testing.expect(c.access(&leftover, c.F_OK) == 0);
    // The next launch is refused only for the missing binary, not the leftover.
    try std.testing.expect(!pair.eng.ensure());
    try std.testing.expectEqualStrings(MISSING_MSG, pair.eng.reason);
    try std.testing.expect(pair.eng.private_dir == null);
    try std.testing.expectEqual(@as(c_int, 0), c.rmdir(&leftover));
}

test "a runtime dir too long for Chromium's singleton socket fails the launch closed" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    var deep: [256:0]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&deep, "{s}/{s}", .{ pair.stateDir(), "r" ** 40 });
    try std.testing.expectEqual(@as(c_int, 0), c.mkdir(dir.ptr, 0o700));
    var runtime = try EnvPin.set("XDG_RUNTIME_DIR", dir.ptr);
    defer runtime.restore();
    var bin = try EnvPin.set("SKETERM_WEB_BIN", "/bin/sh");
    defer bin.restore();
    pair.eng.untrusted = true;
    pair.eng.stopUntrusted();
    try std.testing.expect(!pair.eng.ensure());
    try std.testing.expect(std.mem.indexOf(u8, pair.eng.reason, "too long") != null);
    try std.testing.expect(pair.eng.private_dir == null);
    try std.testing.expectEqual(@as(c.pid_t, -1), pair.eng.pid);
}

test "untrusted roots live in a private per-user parent" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    const base = pair.stateDir();
    var buf: [4096]u8 = undefined;
    var path: [512:0]u8 = undefined;
    const made = untrustedParent(base, &buf) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.endsWith(u8, made, "/" ++ UNTRUSTED_PARENT));
    var st: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.lstat(made.ptr, &st));
    try std.testing.expectEqual(@as(c_uint, 0o700), st.st_mode & 0o7777);
    // A loosened untrusted dir of ours is tightened in place.
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(made.ptr, 0o755));
    _ = untrustedParent(base, &buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(c_int, 0), c.lstat(made.ptr, &st));
    try std.testing.expectEqual(@as(c_uint, 0o700), st.st_mode & 0o7777);
    // A group-writable sketerm level is refused, never repaired.
    _ = try std.fmt.bufPrintZ(&path, "{s}/sketerm", .{base});
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(&path, 0o775));
    try std.testing.expect(untrustedParent(base, &buf) == null);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(&path, 0o700));
    // A symlink in place of the untrusted dir is refused.
    _ = try std.fmt.bufPrintZ(&path, "{s}/" ++ UNTRUSTED_PARENT, .{base});
    try std.testing.expectEqual(@as(c_int, 0), c.rmdir(&path));
    try std.testing.expectEqual(@as(c_int, 0), c.symlink("/tmp", &path));
    try std.testing.expect(untrustedParent(base, &buf) == null);
    try std.testing.expectEqual(@as(c_int, 0), c.unlink(&path));
    // A world-writable runtime dir without the sticky bit is refused.
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(@ptrCast(&pair.tmpl), 0o777));
    try std.testing.expect(untrustedParent(base, &buf) == null);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(@ptrCast(&pair.tmpl), 0o1777));
    try std.testing.expect(untrustedParent(base, &buf) != null);
    try std.testing.expectEqual(@as(c_int, 0), c.chmod(@ptrCast(&pair.tmpl), 0o700));
}

/// A stand-in cleanup owner: exits with `code` once its lifetime fence
/// closes, or ignores SIGTERM and the fence entirely when `stubborn`.
fn fakeOwner(code: u8, stubborn: bool) !struct { pid: c.pid_t, fence: c_int } {
    var fds: [2]c_int = undefined;
    if (c.pipe(&fds) != 0) return error.SkipZigTest;
    var ready: [2]c_int = undefined;
    if (c.pipe(&ready) != 0) return error.SkipZigTest;
    defer _ = c.close(ready[0]);
    const pid = c.fork();
    if (pid < 0) return error.SkipZigTest;
    if (pid == 0) {
        _ = c.close(fds[1]);
        _ = c.close(ready[0]);
        // A real owner takes SIGTERM through its signalfd and keeps going.
        const Ignore = struct {
            fn signal(_: c_int) callconv(.c) void {}
        };
        _ = c.signal(c.SIGTERM, &Ignore.signal);
        _ = c.close(ready[1]);
        if (stubborn) while (true) {
            _ = c.pause();
        };
        var byte: u8 = 0;
        while (c.read(fds[0], &byte, 1) > 0) {}
        c._exit(code);
    }
    _ = c.close(fds[0]);
    _ = c.close(ready[1]);
    // EOF once the child installed its handler.
    var byte: u8 = 0;
    _ = c.read(ready[0], &byte, 1);
    return .{ .pid = pid, .fence = fds[1] };
}

test "untrusted teardown has one deadline, escalates to SIGKILL and is idempotent" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    pair.eng.untrusted = true;
    pair.eng.untrusted_grace_ms = 300;
    pair.eng.untrusted_retire_ms = 200;

    // A failed start skips the graceful wait: the fence closes at once.
    const quick = try fakeOwner(0, false);
    pair.eng.pid = quick.pid;
    pair.eng.private_lifetime = quick.fence;
    var started = clock.nowMs();
    pair.eng.killChild();
    try std.testing.expect(clock.nowMs() - started < 250);
    try std.testing.expectEqual(UntrustedCleanup.deleted, pair.eng.untrusted_cleanup);
    try std.testing.expectEqual(@as(c.pid_t, -1), pair.eng.pid);

    // An owner that gave up deleting reports it.
    const failed = try fakeOwner(SUPERVISOR_CLEANUP_FAILED, false);
    pair.eng.pid = failed.pid;
    pair.eng.private_lifetime = failed.fence;
    pair.eng.stopUntrusted();
    try std.testing.expectEqual(UntrustedCleanup.gave_up, pair.eng.untrusted_cleanup);

    // A stuck owner costs exactly grace + retire, then SIGKILL.
    const stuck = try fakeOwner(0, true);
    pair.eng.pid = stuck.pid;
    pair.eng.private_lifetime = stuck.fence;
    started = clock.nowMs();
    pair.eng.stopUntrusted();
    const took = clock.nowMs() - started;
    try std.testing.expect(took >= 500 and took < 1500);
    try std.testing.expectEqual(UntrustedCleanup.owner_killed, pair.eng.untrusted_cleanup);
    try std.testing.expectEqual(@as(c.pid_t, -1), pair.eng.pid);
    try std.testing.expect(c.kill(stuck.pid, 0) != 0);
    // Repeated stops (killChild, lost, the launch's defer) cost nothing more.
    started = clock.nowMs();
    pair.eng.killChild();
    pair.eng.stopUntrusted();
    try std.testing.expect(clock.nowMs() - started < 50);
}

test "inherited descriptors become close-on-exec on every fallback path" {
    for ([_]CloexecPath{ .close_range, .proc, .rlimit }) |how| {
        var fds: [2]c_int = undefined;
        try std.testing.expectEqual(@as(c_int, 0), c.pipe(&fds));
        defer _ = c.close(fds[0]);
        defer _ = c.close(fds[1]);
        try std.testing.expect(c.fcntl(fds[1], c.F_GETFD) & c.FD_CLOEXEC == 0);
        try std.testing.expect(markCloexecFrom(@min(fds[0], fds[1]), how));
        try std.testing.expect(c.fcntl(fds[0], c.F_GETFD) & c.FD_CLOEXEC != 0);
        try std.testing.expect(c.fcntl(fds[1], c.F_GETFD) & c.FD_CLOEXEC != 0);
    }
}

test "untrusted child environment drops desktop, bus, agent and sketerm endpoints" {
    const names = [_][*:0]const u8{ "SKETERM_MUX_SOCKET", "SKETERM_WEB_WREQ_TIMEOUT_MS", "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "SSH_AUTH_SOCK", "SKETERM_WEB_GPU", "SKETERM_UNIT_KEEP" };
    var pins: [names.len]EnvPin = undefined;
    for (names, 0..) |n, i| pins[i] = try EnvPin.set(n, "x");
    defer for (&pins) |*p| p.restore();
    var env = try ChildEnv.build(std.testing.allocator, &untrusted_env.dropped, &untrusted_env.sets);
    defer env.deinit();
    var seen = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer seen.deinit();
    var i: usize = 0;
    while (env.envp[i]) |entry| : (i += 1) {
        const text = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, text, '=').?;
        try std.testing.expect(!seen.contains(text[0..eq]));
        try seen.put(text[0..eq], text[eq + 1 ..]);
    }
    for ([_][]const u8{ "SKETERM_MUX_SOCKET", "SKETERM_UNIT_KEEP", "DBUS_SESSION_BUS_ADDRESS", "WAYLAND_DISPLAY", "SSH_AUTH_SOCK" }) |n|
        try std.testing.expect(!seen.contains(n));
    try std.testing.expectEqualStrings("x", seen.get("SKETERM_WEB_WREQ_TIMEOUT_MS").?);
    try std.testing.expectEqualStrings("0", seen.get("SKETERM_WEB_GPU").?);
    try std.testing.expectEqualStrings("headless", seen.get("SKETERM_WEB_OZONE").?);
}

test "port narrowing preserves accounting and rejects reopening all ports" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    pair.eng.caps.insert(.net_policy);
    const policy = NetPolicy{ .allow_top = &.{"site.example"} };
    const view = try pair.eng.openViewIn("https://site.example/", 800, 600, .default, &policy);
    view.pol_requests = 7;
    try pair.policyAck(view);
    const report = try pair.eng.tightenViewPolicy(view.id, &.{ .allow_top = &.{"site.example:443"} });
    try std.testing.expectEqual(@as(usize, 1), report.n_tightened);
    try std.testing.expectEqualStrings("site.example:443", view.pol.?.allow_top[0]);
    try std.testing.expectEqual(@as(u32, 7), view.pol_requests);
    const refused = try pair.eng.tightenViewPolicy(view.id, &.{ .allow_top = &.{"site.example"} });
    try std.testing.expectEqual(@as(usize, 1), refused.n_ignored);
    try std.testing.expectEqual(@as(usize, 0), refused.n_tightened);
}

test "untrusted teardown tolerates socket loss while destroying a view or context" {
    const Ignore = struct {
        fn signal(_: c_int) callconv(.c) void {}
    };
    const old_signal = c.signal(c.SIGPIPE, &Ignore.signal);
    defer _ = c.signal(c.SIGPIPE, old_signal);
    for ([_]bool{ false, true }) |context_only| {
        var pair = try Pair.init(std.testing.allocator);
        defer pair.deinit();
        pair.eng.untrusted = true;
        pair.eng.caps.insert(.untrusted_web);
        pair.eng.caps.insert(.net_policy);
        const policy = NetPolicy{ .untrusted = true, .allow_top = &.{"site.example:443"} };
        const view = try pair.openPolicyAck(&policy);
        try std.testing.expectEqual(@as(c_int, 0), c.shutdown(pair.eng.fd, c.SHUT_WR));
        if (context_only) pair.eng.releaseContext(view.context) else pair.eng.closeView(view.id);
        try std.testing.expectEqual(@as(usize, 0), pair.eng.views.items.len);
        try std.testing.expectEqual(@as(usize, 0), pair.eng.live.items.len);
        try std.testing.expectEqual(@as(c_int, -1), pair.eng.fd);
    }
}

test "coordinate input reaches the wire as the GUI's own frames" {
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    var buf: [8192]u8 = undefined;
    const view = try pair.eng.openViewIn("https://site.example/", 800, 600, .default, null);
    // Painted once already, so no input waits for a first frame.
    view.frame_gen = 1;
    _ = pair.drain(&buf);

    // 1. A button edge, a wheel step and one key edge go out as given.
    try pair.eng.sendInput(proto.InputPointer{ .view = view.id, .kind = @intFromEnum(proto.PointerKind.down), .x = 120, .y = 45, .button = 2, .clicks = 1, .mods = proto.mod_shift });
    try pair.eng.sendInput(proto.InputScroll{ .view = view.id, .x = 400, .y = 300, .dx = 0, .dy = 120, .mods = 0 });
    try pair.eng.sendInput(proto.InputKey{ .view = view.id, .kind = @intFromEnum(proto.KeyKind.down), .keyval = 0xffe1, .keycode = 0, .mods = 0, .text = "" });
    {
        var reader = proto.Reader.init(pair.drain(&buf));
        const down = try proto.decode(proto.InputPointer, (try reader.next()).?.payload);
        try std.testing.expectEqual(@as(i32, 45), down.y);
        try std.testing.expectEqual(proto.mod_shift, down.mods);
        try std.testing.expectEqual(@as(i32, 120), (try proto.decode(proto.InputScroll, (try reader.next()).?.payload)).dy);
        try std.testing.expectEqual(@as(u32, 0xffe1), (try proto.decode(proto.InputKey, (try reader.next()).?.payload)).keyval);
        try std.testing.expect((try reader.next()) == null);
    }

    // 2. Text insertion needs the helper's clipboard capability; without it nothing is sent.
    const paste = proto.InputPaste{ .view = view.id, .text = .{ .s = "h\u{e9}llo" } };
    try std.testing.expectError(error.NoTextInput, pair.eng.sendInput(paste));
    try std.testing.expectEqual(@as(usize, 0), pair.drain(&buf).len);
    pair.eng.caps.insert(.clipboard);
    try pair.eng.sendInput(paste);
    {
        var reader = proto.Reader.init(pair.drain(&buf));
        try std.testing.expectEqualStrings("h\u{e9}llo", (try proto.decode(proto.InputPaste, (try reader.next()).?.payload)).text.s);
    }
    try std.testing.expectError(error.NoView, pair.eng.sendInput(proto.InputScroll{ .view = view.id + 99, .x = 0, .y = 0, .dx = 0, .dy = 0, .mods = 0 }));
}

test "frameAfter answers a newer paint at once, and nothing when the page stayed still" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var pair = try Pair.init(std.testing.allocator);
    defer pair.deinit();
    const view = try pair.eng.openViewIn("https://site.example/", 800, 600, .default, null);

    // 1. No frame painted yet: a short wait answers "nothing newer", never an error.
    try std.testing.expect((try pair.eng.frameAfter(arena, view.id, 0, 30)) == null);

    // 2. A 4x2 BGRX buffer at serial 3 is returned for any older serial, as RGBA with the logical viewport.
    const fd = platform.anonFileFd(4 * 2 * 4);
    try std.testing.expect(fd >= 0);
    var pixels: [4 * 2 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        pixels[i] = 0xcc; // B
        pixels[i + 1] = 0x66; // G
        pixels[i + 2] = 0x33; // R
        pixels[i + 3] = 0;
    }
    try std.testing.expectEqual(@as(isize, pixels.len), c.write(fd, &pixels, pixels.len));
    view.buf_fd = fd;
    view.buf_w = 4;
    view.buf_h = 2;
    view.buf_stride = 16;
    view.frame_gen = 3;
    const frame = (try pair.eng.frameAfter(arena, view.id, 0, 30)).?;
    try std.testing.expectEqual(@as(u32, 3), frame.gen);
    try std.testing.expectEqual(@as(u16, 4), frame.w);
    try std.testing.expectEqual(@as(u16, 800), frame.view_w);
    try std.testing.expectEqual(@as(u16, 600), frame.view_h);
    try std.testing.expectEqualSlices(u8, &.{ 0x33, 0x66, 0xcc, 0xff }, frame.rgba[0..4]);

    // 3. Asking past the serial already drawn waits for a paint that never comes: null, not the same frame again.
    try std.testing.expect((try pair.eng.frameAfter(arena, view.id, 3, 30)) == null);
    // 4. The next paint is answered.
    view.frame_gen = 4;
    try std.testing.expectEqual(@as(u32, 4), (try pair.eng.frameAfter(arena, view.id, 3, 30)).?.gen);
}
