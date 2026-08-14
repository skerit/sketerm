//! Headless driver for `sketerm-webengine`: spawns and owns a private
//! browser helper and speaks the v1 wire protocol (src/web/protocol.zig)
//! as its one client, so the `web_*` MCP tools work with NO GUI at all.
//! The sibling of appdrive.zig in every respect: GTK-free, owns its
//! backend process, and every socket operation is non-blocking with a
//! deadline — a wedged helper costs one described error, never a hang.
//!
//! Views here are HELPER views, not GUI panes: there is no widget, no
//! tab and no user looking at them. The helper runs CEF with
//! `--ozone-platform=headless` (no GPU process, software raster), which
//! is the correct configuration for an unattended browser.
//!
//! ## Discoverability (a future "view along" GUI)
//!
//! The helper socket lives at the WELL-KNOWN name `web.sock` inside the
//! MCP instance directory (`$XDG_RUNTIME_DIR/sketerm/mcp-tmp-<pid>/` or
//! `mcp-<name>/`), next to a presence file `web.json`:
//!   {"mcp_pid":N,"helper_pid":N,"client":"sketerm-mcp[:name]","started_at_ms":N}
//! written when the helper comes up and unlinked with it, so a GUI can
//! enumerate assistant browser sessions by scanning the instance dirs.
//! NOTE for that future feature: src/web/server.zig serves exactly ONE
//! client and exits when it disconnects — a second (viewer) client
//! needs multi-client support there first. This driver deliberately
//! assumes nothing beyond "I created my views": view ids are engine
//! scoped, not connection scoped.

const std = @import("std");
const c = @import("../c.zig").c;
const platform = @import("../util/platform.zig");
const proto = @import("../web/protocol.zig");
const reader_model = @import("../web/reader.zig");
const reader_guards = @import("../web/reader_guards.zig");
const findbin = @import("../web/findbin.zig");
const png = @import("../util/png.zig");
const quarantine = @import("../web/quarantine.zig");
const clock = @import("../util/clock.zig");

/// Default logical size a headless view is created at. There is no
/// allocation to inherit one from, and pages lay out sanely at a
/// laptop-ish viewport.
pub const DEFAULT_W: u16 = 1280;
pub const DEFAULT_H: u16 = 800;

/// How long a freshly spawned helper gets to bind its socket. CEF's
/// startup (re-exec, zygote) dominates; matches the GUI's 150x100ms.
const SPAWN_WAIT_MS: i64 = 15_000;

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

    fn deinit(self: *View, gpa: std.mem.Allocator) void {
        if (self.url) |u| gpa.free(u);
        if (self.title) |t| gpa.free(t);
        if (self.last_eval) |e| gpa.free(e);
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

pub const Engine = struct {
    gpa: std.mem.Allocator,
    /// Directory holding the helper socket and its cache; owned.
    dir: []u8,
    /// Hello identity ("sketerm-mcp" or "sketerm-mcp:<instance>"), so
    /// helper logs and a future viewer can attribute the session to an
    /// assistant rather than an anonymous client. Owned.
    client_name: []u8,
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
    next_sem_request: u32 = 1,

    pub fn init(gpa: std.mem.Allocator, dir: []const u8, instance: ?[]const u8) !Engine {
        const owned_dir = try gpa.dupe(u8, dir);
        errdefer gpa.free(owned_dir);
        const name = if (instance) |n|
            try std.fmt.allocPrint(gpa, "sketerm-mcp:{s}", .{n})
        else
            try gpa.dupe(u8, "sketerm-mcp");
        return .{ .gpa = gpa, .dir = owned_dir, .client_name = name };
    }

    /// Kill and reap the helper; safe to call from a signal-driven
    /// teardown path (the helper also exits on its own when this
    /// process's socket closes).
    pub fn deinit(self: *Engine) void {
        self.dropConnection();
        if (self.pid > 0) {
            _ = c.kill(self.pid, c.SIGTERM);
            var tries: u32 = 0;
            var status: c_int = 0;
            while (tries < 40) : (tries += 1) {
                if (c.waitpid(self.pid, &status, c.WNOHANG) == self.pid) break;
                _ = c.usleep(50_000);
            }
            if (tries >= 40) {
                _ = c.kill(self.pid, c.SIGKILL);
                _ = c.waitpid(self.pid, &status, 0);
            }
            self.pid = -1;
        }
        self.removePresence();
        self.clearViews();
        self.views.deinit(self.gpa);
        self.in.deinit(self.gpa);
        self.rx_fds.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.gpa.free(self.client_name);
        self.state = .idle;
    }

    /// Write `web.json` next to the socket (see the header). Best
    /// effort: enumeration metadata, never load-bearing.
    fn writePresence(self: *Engine) void {
        var path_z: [4096:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&path_z, "{s}/web.json", .{self.dir}) catch return;
        const f = c.fopen(p.ptr, "w") orelse return;
        defer _ = c.fclose(f);
        var line: [512]u8 = undefined;
        const s = std.fmt.bufPrint(&line, "{{\"mcp_pid\":{d},\"helper_pid\":{d},\"client\":\"{s}\",\"started_at_ms\":{d}}}\n", .{
            c.getpid(), self.pid, self.client_name, clock.nowMs(),
        }) catch return;
        _ = c.fwrite(s.ptr, 1, s.len, f);
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
        self.cap_shm = false;
        self.cap_semantic = false;
        self.cap_reader_ids = false;
        self.cap_semantic_request_ids = false;
        self.cap_view_url = false;
        self.cap_intercept = false;
        self.removePresence();
        self.state = .unavailable;
        self.reason = LOST_MSG;
        self.retryable = true;
    }

    /// Bring the helper up if it is not already. Bounded: a missing
    /// binary or a helper that never binds leaves `.unavailable` with
    /// `reason` set, and the caller reports that instead of hanging.
    pub fn ensure(self: *Engine) bool {
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
        var cache_z: [4096:0]u8 = undefined;
        _ = std.fmt.bufPrintZ(&cache_z, "{s}/web-cache", .{self.dir}) catch return self.failStart("helper cache path too long");
        // A stale socket from a crashed helper would make the connect
        // succeed against nothing.
        _ = c.unlink(sock.ptr);

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
            var argv: [6:null]?[*:0]const u8 = .{ bin, "--socket", &sock_z, "--cache-dir", &cache_z, null };
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
        if (self.state == .ready) self.writePresence();
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
        if (!self.ensure()) return error.Unavailable;
        const v = try self.gpa.create(View);
        errdefer self.gpa.destroy(v);
        v.* = .{ .id = self.next_view, .w = w, .h = h };
        self.next_view += 1;
        try self.views.append(self.gpa, v);
        if (url.len > 0 and self.cap_view_url) {
            self.send(proto.ViewCreateUrl{
                .view = v.id,
                .w = w,
                .h = h,
                .scale_x1000 = 1000,
                .context = 0,
                .url = url,
            }) catch return error.Unavailable;
        } else {
            self.send(proto.ViewCreate{
                .view = v.id,
                .w = w,
                .h = h,
                .scale_x1000 = 1000,
                .context = 0,
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

    pub fn closeView(self: *Engine, id: u32) void {
        for (self.views.items, 0..) |v, i| {
            if (v.id != id) continue;
            if (self.state == .ready) self.send(proto.ViewDestroy{ .view = id }) catch {};
            v.deinit(self.gpa);
            self.gpa.destroy(v);
            _ = self.views.orderedRemove(i);
            if (self.current == id)
                self.current = if (self.views.items.len > 0) self.views.items[self.views.items.len - 1].id else 0;
            return;
        }
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
        self.send(proto.InterceptLogReq{ .view = id, .since = since, .max = max }) catch return error.Unavailable;
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
                for (ack.caps) |cap| {
                    if (std.mem.eql(u8, cap, proto.CAP_FRAMES_SHM)) self.cap_shm = true;
                    if (std.mem.eql(u8, cap, proto.CAP_SEMANTIC)) self.cap_semantic = true;
                    if (std.mem.eql(u8, cap, proto.CAP_VIEW_CREATE_URL)) self.cap_view_url = true;
                    if (std.mem.eql(u8, cap, proto.CAP_INTERCEPT)) self.cap_intercept = true;
                    if (std.mem.eql(u8, cap, proto.CAP_READER_IDS)) self.cap_reader_ids = true;
                    if (std.mem.eql(u8, cap, proto.CAP_SEMANTIC_REQUEST_IDS)) self.cap_semantic_request_ids = true;
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
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null);
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
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null);
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
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null);
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
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null);
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

test "the current view is the last one touched, not the oldest" {
    const gpa = std.testing.allocator;
    var eng = try Engine.init(gpa, "/tmp/webdrive-test", null);
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
