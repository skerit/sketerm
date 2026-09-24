//! `Client` — the connection to one `sketerm-webengine` helper process:
//! spawn/connect, handshake, view-id routing and event dispatch to the
//! faces. Split out of `webface.zig`, which keeps the process-wide
//! client registry (`g_client`, the aux and observer clients).

const std = @import("std");
const c = @import("../../c.zig").c;
const cast = @import("../../util/cast.zig");
const findbin = @import("../../web/findbin.zig");
const mux_cli = @import("../../ipc/mux_cli.zig");
const platform = @import("../../util/platform.zig");
const proto = @import("../../web/protocol.zig");
const socksbridge = @import("../../ipc/socksbridge.zig");
const webext = @import("../webext.zig");
const webremote = @import("../webremote.zig");
const webroute = @import("../../web/route.zig");
const webstore = @import("../webstore.zig");
const webwatch = @import("../webwatch.zig");
const host_mod = @import("../webface.zig");
const CONNECT_INTERVAL_MS = host_mod.CONNECT_INTERVAL_MS;
const CONNECT_MAX_TRIES = host_mod.CONNECT_MAX_TRIES;
const LOST_MSG = host_mod.LOST_MSG;
const MISSING_MSG = host_mod.MISSING_MSG;
const WebFace = host_mod.WebFace;
const cookieSyncOnReady = host_mod.cookieSyncOnReady;
const onCookieChange = host_mod.onCookieChange;
const onCookieDump = host_mod.onCookieDump;
const publishContexts = host_mod.publishContexts;
const publishFilterSubs = host_mod.publishFilterSubs;
const tabsChanged = host_mod.tabsChanged;

// ---------------------------------------------------------------------
// Client — one helper process per GUI process
// ---------------------------------------------------------------------

pub const Client = struct {
    pub const State = enum { idle, connecting, ready, unavailable };

    gpa: std.mem.Allocator = undefined,
    /// `gpa`/`out` are set on the FIRST ensure and reused for the
    /// process's life; a restart re-uses them rather than leaking the
    /// outbox's buffer.
    initialized: bool = false,
    state: State = .idle,
    /// Why `state == .unavailable`. Static strings only.
    reason: []const u8 = "",
    /// False for "the binary is not installed", where a retry can only
    /// fail the same way; true for anything a restart might fix.
    reason_retryable: bool = true,
    fd: c_int = -1,
    pid: c.pid_t = -1,
    /// This client JOINED a helper another sketerm process started
    /// (`adoptRunningHelper`): it owns no child and no socket file.
    adopted: bool = false,
    /// Our own helper lost the startup race; the connect ticks are now
    /// looking for the winner's socket instead of ours.
    adopt_retry: bool = false,
    sock_path: [108]u8 = undefined,
    sock_len: usize = 0,
    /// Remote helper host ("" = the local helper this GUI spawns). A
    /// remote client's `fd` is one end of a socketpair whose other end
    /// a `webremote.Bridge` worker pumps to a helper the REMOTE mux
    /// daemon spawned (`web_helper_open`); such a helper runs
    /// `--frames-inline`, so every frame arrives in-band and no
    /// SCM_RIGHTS descriptor ever needs to cross.
    host: [256]u8 = undefined,
    host_len: usize = 0,
    /// The route this instance realizes. One helper process per route is
    /// what makes routing correct by construction (see `src/web/route.zig`):
    /// this instance's profile and proxy are the route's, so it has no path
    /// to any other one. Stored as kind + lengths rather than a `Spec` with
    /// slices, so the struct holds no pointers into itself.
    route_kind: webroute.Kind = .direct,
    route_host: [256]u8 = undefined,
    route_host_len: usize = 0,
    route_endpoint: [64]u8 = undefined,
    route_endpoint_len: usize = 0,
    /// Cached `--cache-dir`, minted with the socket path.
    cache_dir: [128:0]u8 = undefined,
    cache_dir_len: usize = 0,
    bridge: ?*webremote.Bridge = null,
    /// The loopback SOCKS5 -> mux bridge a `.mux` route instance's
    /// proxy points at. Created on the first `ensure`, kept across
    /// helper restarts (its port is baked into the helper's argv only
    /// per spawn, so a restart re-reads it), never freed: clients are
    /// immortal.
    egress: ?*socksbridge.Egress = null,
    /// Storage for a formatted (non-static) unavailable reason; stable
    /// because clients are never freed.
    reason_buf: [384]u8 = undefined,
    in: std.ArrayList(u8) = .empty,
    out: proto.Outbox = undefined,
    /// Descriptors received through SCM_RIGHTS, in arrival order. A
    /// `frame_buffer` frame pops the front one — the helper attaches
    /// exactly one fd to exactly that frame.
    fds: std.ArrayList(c_int) = .empty,
    read_watch: c.guint = 0,
    write_watch: c.guint = 0,
    connect_timer: c.guint = 0,
    connect_tries: u32 = 0,
    faces: std.ArrayList(*WebFace) = .empty,
    /// What the CURRENT connection's helper advertised in `hello_ack`;
    /// empty until it arrives and again after every disconnect, because a
    /// restart may land on a different helper build. Every feature a
    /// helper may lack degrades by construction: a verb it does not
    /// advertise is never posted, and its menu row is insensitive rather
    /// than hidden, so it stays discoverable.
    caps: proto.Caps = .initEmpty(),
    /// The current connection's `hello_ack` has arrived. Container views
    /// wait for it, because whether the helper can keep a container's
    /// identity apart (`contexts-fail-closed`) is only known from it.
    hello_done: bool = false,
    /// `cookie_sync_enable` was posted on the CURRENT connection.
    sync_enabled: bool = false,

    /// An OBSERVER client (`webwatch.zig`): a second connection to an
    /// ASSISTANT's helper that only watches (and, with control,
    /// drives) that helper's views through the "observe" capability.
    /// It mints no views of its own and publishes NOTHING into the
    /// helper: no extensions, no user content, no containers, no
    /// filter lists, and above all no cookie sync, which would pour
    /// this user's jars into the assistant's. Every "on hello_ack"
    /// hook below is gated on it.
    observer: bool = false,
    /// Local helper socket to connect to (observer, non-remote).
    obs_local: [108]u8 = undefined,
    obs_local_len: usize = 0,
    /// The assistant's web session on a REMOTE host (observer + host):
    /// what `web_helper_connect` names to the remote daemon.
    obs_session: [64]u8 = undefined,
    obs_session_len: usize = 0,
    /// Identity an observer client was minted for; an idle one with the
    /// same key is reused by the next watch on that assistant.
    obs_key: [384]u8 = undefined,
    obs_key_len: usize = 0,
    /// The `webwatch.Watch` this observer client serves, nulled by the
    /// watch before it frees itself (the back-pointer fence).
    watch: ?*anyopaque = null,

    pub fn hostSlice(self: *const Client) []const u8 {
        return self.host[0..self.host_len];
    }

    /// This client's route. A `route: Spec` field would hold slices into
    /// `self`; this rebuilds them instead.
    pub fn routeSpec(self: *const Client) webroute.Spec {
        return .{
            .kind = self.route_kind,
            .host = self.route_host[0..self.route_host_len],
            .endpoint = self.route_endpoint[0..self.route_endpoint_len],
        };
    }

    pub fn isRemote(self: *const Client) bool {
        return self.host_len != 0;
    }

    /// Whether the current connection's helper advertised `cap`.
    pub fn has(self: *const Client, cap: proto.Cap) bool {
        return self.caps.contains(cap);
    }

    /// Bring the helper up if it is not already. Never blocks: a
    /// missing binary or a helper that never answers leaves the client
    /// `.unavailable` and every face showing `reason`.
    pub fn ensure(self: *Client, gpa: std.mem.Allocator) void {
        if (self.state != .idle) return;
        if (!self.initialized) {
            self.gpa = gpa;
            self.out = proto.Outbox.init(gpa);
            self.initialized = true;
        }
        if (self.isRemote()) {
            self.ensureRemote();
            return;
        }
        if (self.observer) {
            self.ensureObserverLocal();
            return;
        }

        // One CEF process per profile: join the helper another sketerm
        // window is already running rather than forking a rival that
        // cannot initialize (`adoptRunningHelper`).
        if (self.adoptRunningHelper()) return;

        var bin_buf: [4096:0]u8 = undefined;
        const bin = findbin.find(&bin_buf) orelse {
            self.failWith(MISSING_MSG, false);
            return;
        };
        const path = self.makeSocketPath() orelse {
            self.fail("No usable runtime directory for the browser helper socket.");
            return;
        };
        // A stale socket file from a crashed helper would make our
        // connect succeed against nothing; the helper unlinks it too,
        // but only once it gets that far.
        var path_z: [128:0]u8 = undefined;
        if (path.len + 1 > path_z.len) {
            self.fail("Runtime directory path is too long for a unix socket.");
            return;
        }
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        _ = c.unlink(&path_z);

        // Derived (and its directories created) in the PARENT: a failure
        // here must fail the client with a message, not leave a forked
        // child to exit 127 silently. Null = the default route, which
        // keeps the helper's own HOME-derived profile.
        const cache_dir: ?[:0]const u8 = if (self.routeSpec().isDirect()) null else self.makeCacheDir() orelse {
            self.fail("No usable state directory for this route's browser profile.");
            return;
        };
        // The route's proxy, applied by the helper to its GLOBAL request
        // context and to every container context it mints, so no view of
        // this instance has a direct path. Null for a direct instance.
        var proxy_z: [96:0]u8 = undefined;
        const proxy: ?[:0]const u8 = blk: {
            var pbuf: [80]u8 = undefined;
            const url = (socksbridge.routeProxy(self.gpa, self.routeSpec(), &self.egress, mux_cli.muxConnect, &pbuf) catch {
                self.fail("Could not start the egress bridge for this route (the mux host is unreachable or the loopback listener would not bind).");
                return;
            }) orelse break :blk null;
            if (url.len + 1 > proxy_z.len) {
                self.fail("The route's proxy url is too long.");
                return;
            }
            @memcpy(proxy_z[0..url.len], url);
            proxy_z[url.len] = 0;
            break :blk proxy_z[0..url.len :0];
        };

        const pid = c.fork();
        if (pid == 0) {
            // stdin/stdout to /dev/null so the helper can never wedge a
            // pipeline the GUI sits in; stderr stays, it is where CEF
            // reports refusals.
            const devnull = c.open("/dev/null", c.O_RDWR);
            if (devnull >= 0) {
                _ = c.dup2(devnull, 0);
                _ = c.dup2(devnull, 1);
                if (devnull > 2) _ = c.close(devnull);
            }
            var argv: [8:null]?[*:0]const u8 = .{ bin, "--socket", &path_z, null, null, null, null, null };
            var n: usize = 3;
            if (cache_dir) |cd| {
                argv[n] = "--cache-dir";
                argv[n + 1] = cd.ptr;
                n += 2;
            }
            if (proxy) |pr| {
                argv[n] = "--proxy";
                argv[n + 1] = pr.ptr;
                n += 2;
            }
            _ = c.execv(bin, @ptrCast(@constCast(&argv)));
            c._exit(127);
        }
        if (pid < 0) {
            self.fail("Could not start the browser helper (fork failed).");
            return;
        }
        self.pid = pid;
        self.state = .connecting;
        self.connect_tries = 0;
        self.connect_timer = c.g_timeout_add(CONNECT_INTERVAL_MS, @ptrCast(&onConnectTick), self);
    }

    /// Remote helper: adopt the bridge's socketpair end as the protocol
    /// socket and let the worker connect the mux transport behind it.
    /// The Client goes `.ready` immediately — outbound frames buffer in
    /// the socketpair until the bridge comes up, and a bridge failure
    /// surfaces as a HUP whose reason `lost()` collects. The inline
    /// frame family is REQUIRED on this path; `hello_ack` enforces it.
    fn ensureRemote(self: *Client) void {
        const br = webremote.Bridge.create(self.gpa, self.hostSlice()) orelse {
            self.fail("Could not create the remote browser bridge.");
            return;
        };
        // An observer joins the helper serving the assistant's session
        // on that host instead of having one spawned.
        if (self.observer) br.setConnectSession(self.obs_session[0..self.obs_session_len]);
        const fd = br.guiFd();
        if (fd < 0) {
            br.stop();
            self.fail("Could not create the remote browser bridge.");
            return;
        }
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        self.bridge = br;
        self.fd = fd;
        self.state = .ready;
        self.read_watch = c.g_unix_fd_add(
            fd,
            c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
            @ptrCast(&onReadable),
            self,
        );
        br.spawn();
        self.post(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = "sketerm-gui" });
        // Before any view exists (the frame-mode contract): everything
        // this helper ever paints must arrive in-band.
        self.post(proto.FrameMode{ .mode = proto.frame_mode_inline });
        if (!self.observer) publishContexts(self);
        for (self.faces.items) |f| f.onClientReady();
    }

    /// Observer of a LOCAL assistant: connect to its helper socket
    /// directly (no spawn, no retry loop: the helper is either serving
    /// or the assistant is gone).
    fn ensureObserverLocal(self: *Client) void {
        const path = self.obs_local[0..self.obs_local_len];
        if (path.len == 0 or path.len + 1 > self.sock_path.len) {
            self.failWith("The assistant's browser helper socket path is unusable.", false);
            return;
        }
        @memcpy(self.sock_path[0..path.len], path);
        self.sock_len = path.len;
        if (!self.tryConnect())
            self.failWith("The assistant's browser is not running (its helper socket does not answer).", false);
    }

    /// End an observer connection deliberately (the watch closed):
    /// the helper drops every subscription on EOF and its owner never
    /// notices. The client goes back to idle so the next watch on the
    /// same assistant can reuse it.
    pub fn stopObserving(self: *Client) void {
        if (!self.observer) return;
        self.watch = null;
        self.teardownConnection();
        self.state = .idle;
        self.reason = "";
    }

    /// Drop everything and allow a later `ensure` to start over. The
    /// crashed/lost overlay's Reload button is the user-facing route.
    pub fn restart(self: *Client) void {
        if (self.state == .ready or self.state == .connecting) return;
        if (self.pid > 0) {
            _ = c.kill(self.pid, c.SIGTERM);
            self.reap();
        }
        self.state = .idle;
        self.reason = "";
        self.ensure(self.gpa);
        // Faces re-create their views as soon as the handshake lands.
    }

    fn fail(self: *Client, reason: []const u8) void {
        self.failWith(reason, true);
    }

    fn failWith(self: *Client, reason: []const u8, retryable: bool) void {
        if (!self.isRemote() and !self.observer) webext.onHelperUnavailable();
        self.teardownConnection();
        self.state = .unavailable;
        self.reason = reason;
        self.reason_retryable = retryable;
        for (self.faces.items) |f| f.onHelperUnavailable(reason, retryable);
        if (self.observer) webwatch.onClientLost(self);
    }

    fn teardownConnection(self: *Client) void {
        if (self.read_watch != 0) {
            _ = c.g_source_remove(self.read_watch);
            self.read_watch = 0;
        }
        if (self.write_watch != 0) {
            _ = c.g_source_remove(self.write_watch);
            self.write_watch = 0;
        }
        if (self.connect_timer != 0) {
            _ = c.g_source_remove(self.connect_timer);
            self.connect_timer = 0;
        }
        if (self.fd >= 0) {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        // Capabilities belong to the CONNECTION, not to the client: a
        // restart may land on a different helper build.
        self.caps = .initEmpty();
        self.sync_enabled = false;
        self.hello_done = false;
        self.adopted = false;
        if (self.bridge) |br| {
            self.bridge = null;
            br.stop();
        }
        for (self.fds.items) |fd| _ = c.close(fd);
        self.fds.clearRetainingCapacity();
        self.in.clearRetainingCapacity();
        while (self.out.front()) |m| self.out.advance(m.bytes.len);
    }

    /// Non-blocking child reap. The helper is our own child, so an
    /// unreaped exit would be a zombie for the GUI's lifetime.
    fn reap(self: *Client) void {
        if (self.pid <= 0) return;
        var status: c_int = 0;
        const r = c.waitpid(self.pid, &status, c.WNOHANG);
        if (r == self.pid) self.pid = -1;
    }

    fn makeSocketPath(self: *Client) ?[]const u8 {
        const rt = platform.runtimeDir();
        var dir_buf: [96:0]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/sketerm", .{rt}) catch return null;
        _ = c.mkdir(dir.ptr, 0o700);
        var slug_buf: [64]u8 = undefined;
        const slug = self.routeSpec().slug(&slug_buf) orelse return null;
        // The default route keeps the historical path so an upgrade does
        // not strand the existing profile (and its logins) behind a new
        // name. Every other route gets its own socket AND its own
        // `--cache-dir`: two CEF processes sharing a root_cache_path is
        // measured-fatal (`cef_initialize` fails, "Opening in existing
        // browser session"), so a collision here would break the browser.
        const p = if (self.routeSpec().isDirect())
            std.fmt.bufPrint(&self.sock_path, "{s}/{s}{d}.sock", .{
                dir,
                @import("../../ipc/server.zig").WEB_SOCKET_PREFIX,
                c.getpid(),
            }) catch return null
        else
            std.fmt.bufPrint(&self.sock_path, "{s}/{s}{d}-{s}.sock", .{
                dir,
                @import("../../ipc/server.zig").WEB_SOCKET_PREFIX,
                c.getpid(),
                slug,
            }) catch return null;
        self.sock_len = p.len;
        return p;
    }

    /// This route's durable profile directory, or null for the default
    /// route (which keeps the helper's own HOME-derived default).
    ///
    /// It is DURABLE, not per-pid: a route's cookies and logins must
    /// survive a GUI restart the way the default profile does.
    fn makeCacheDir(self: *Client) ?[:0]const u8 {
        if (self.routeSpec().isDirect()) return null;
        var slug_buf: [64]u8 = undefined;
        const slug = self.routeSpec().slug(&slug_buf) orelse return null;
        // Same derivation layout.zig and webprofiles.zig use.
        var state_buf: [96]u8 = undefined;
        const state = if (@import("../../util/profile.zig").getenv("XDG_STATE_HOME")) |xs|
            std.fmt.bufPrint(&state_buf, "{s}", .{xs}) catch return null
        else if (@import("../../util/profile.zig").getenv("HOME")) |home|
            std.fmt.bufPrint(&state_buf, "{s}/.local/state", .{home}) catch return null
        else
            return null;
        var base_buf: [128:0]u8 = undefined;
        const base = std.fmt.bufPrintZ(&base_buf, "{s}/sketerm", .{state}) catch return null;
        _ = c.mkdir(base.ptr, 0o700);
        var routes_buf: [128:0]u8 = undefined;
        const routes = std.fmt.bufPrintZ(&routes_buf, "{s}/web-routes", .{base}) catch return null;
        _ = c.mkdir(routes.ptr, 0o700);
        const p = std.fmt.bufPrintZ(&self.cache_dir, "{s}/{s}", .{ routes, slug }) catch return null;
        _ = c.mkdir(p.ptr, 0o700);
        self.cache_dir_len = p.len;
        return p;
    }

    /// A helper that died before binding: the CEF deployment is broken,
    /// or another sketerm process owns the profile and this one raced
    /// in after the socket scan (`adoptRunningHelper` answers that case
    /// first, so reaching this text means neither retry found a helper).
    const HELPER_EXIT_MSG = "The browser helper exited during startup (see its stderr).";

    /// Does `name` name a helper socket of this route that ANOTHER
    /// process owns? `web-<pid>.sock` on the direct route,
    /// `web-<pid>-<slug>.sock` on a routed instance -- so a routed
    /// socket never matches the direct route and vice versa.
    /// The pid of the sketerm process that owns helper socket `name`
    /// on this route, or null when the name is not such a socket (or
    /// is our own).
    pub fn helperSocketOfRoute(name: []const u8, slug: ?[]const u8, self_pid: i32) ?i32 {
        const prefix = @import("../../ipc/server.zig").WEB_SOCKET_PREFIX;
        const suffix = ".sock";
        if (!std.mem.startsWith(u8, name, prefix) or !std.mem.endsWith(u8, name, suffix)) return null;
        const mid = name[prefix.len .. name.len - suffix.len];
        const pid_part = if (slug) |s| blk: {
            if (mid.len <= s.len + 1) return null;
            if (!std.mem.endsWith(u8, mid, s)) return null;
            const cut = mid.len - s.len - 1;
            if (mid[cut] != '-') return null;
            break :blk mid[0..cut];
        } else mid;
        if (pid_part.len == 0) return null;
        for (pid_part) |ch| if (ch < '0' or ch > '9') return null;
        const pid = std.fmt.parseInt(i32, pid_part, 10) catch return null;
        return if (pid != self_pid) pid else null;
    }

    /// Join the helper another sketerm process of this route already
    /// runs, instead of forking a second one.
    ///
    /// A second CEF process on the same `root_cache_path` dies at
    /// startup with `cef_initialize failed` / "Opening in existing
    /// browser session" (MEASURED, and the reason `makeCacheDir` gives
    /// every non-direct route its own directory). The default route
    /// deliberately shares ONE profile so the user's logins are the
    /// same in every window, so a second window could never browse:
    /// its tab said "the browser helper exited during startup" for as
    /// long as another window held a browser page open. The helper
    /// serves several clients (`multi-client`, per-connection view-id
    /// windows), so the fix is to share it.
    ///
    /// The socket file belongs to the process that spawned the helper:
    /// an adopted client reaps no child and unlinks nothing. A socket
    /// whose helper is gone is unlinked here, so the directory heals.
    fn adoptRunningHelper(self: *Client) bool {
        const rt = platform.runtimeDir();
        var dir_buf: [96:0]u8 = undefined;
        const dir = std.fmt.bufPrintZ(&dir_buf, "{s}/sketerm", .{rt}) catch return false;
        var slug_buf: [64]u8 = undefined;
        const slug: ?[]const u8 = if (self.routeSpec().isDirect())
            null
        else
            (self.routeSpec().slug(&slug_buf) orelse return false);
        const d = c.g_dir_open(dir.ptr, 0, null) orelse return false;
        defer c.g_dir_close(d);
        const self_pid: i32 = @intCast(c.getpid());
        while (c.g_dir_read_name(d)) |name_c| {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_c)));
            const owner_pid = helperSocketOfRoute(name, slug, self_pid) orelse continue;
            var path_buf: [108]u8 = undefined;
            const p = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch continue;
            if (p.len + 1 > self.sock_path.len) continue;
            @memcpy(self.sock_path[0..p.len], p);
            self.sock_len = p.len;
            // Set BEFORE the connect: `tryConnect` defers an adopted
            // client's publishing until the helper has confirmed it
            // can serve two clients (`hello_ack`).
            self.adopted = true;
            if (self.tryConnect()) return true;
            self.adopted = false;
            // Nothing listening. Unlink the file only when the sketerm
            // that spawned the helper is GONE: a helper that has bound
            // but not yet listened refuses connections for a moment,
            // and unlinking then would strand a live helper on a
            // nameless socket.
            if (c.kill(owner_pid, 0) != 0 and std.posix.errno(@as(c_int, -1)) == .SRCH) {
                var z: [108:0]u8 = undefined;
                @memcpy(z[0..p.len], p);
                z[p.len] = 0;
                _ = c.unlink(&z);
            }
        }
        self.sock_len = 0;
        return false;
    }

    fn onConnectTick(user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Client, user);
        self.connect_tries += 1;

        // A helper that died on startup (missing libcef, bad CEF
        // deployment) will never bind; say so rather than time out.
        if (self.pid > 0) {
            var status: c_int = 0;
            if (c.waitpid(self.pid, &status, c.WNOHANG) == self.pid) {
                self.pid = -1;
                // Two windows raced for the profile: both found no
                // helper and forked one, and the loser's CEF refused
                // the locked `root_cache_path`. The winner is serving
                // now, so join it instead of reporting a failure.
                self.adopt_retry = true;
            }
        }
        if (self.adopt_retry) {
            // The loser fails INSIDE cef_initialize, while the winner is
            // still initialising and has not bound its socket yet: one
            // immediate look often finds nothing. Keep looking for the
            // rest of the connect budget before calling it an exit.
            if (self.adoptRunningHelper()) {
                self.adopt_retry = false;
                self.connect_timer = 0;
                return 0;
            }
            if (self.connect_tries >= CONNECT_MAX_TRIES) {
                self.adopt_retry = false;
                self.connect_timer = 0;
                self.fail(HELPER_EXIT_MSG);
                return 0;
            }
            return 1;
        }

        if (self.tryConnect()) {
            self.connect_timer = 0;
            return 0;
        }
        if (self.connect_tries >= CONNECT_MAX_TRIES) {
            self.connect_timer = 0;
            self.fail("The browser helper did not answer in time.");
            return 0;
        }
        return 1;
    }

    fn tryConnect(self: *Client) bool {
        var addr = std.mem.zeroes(c.struct_sockaddr_un);
        if (self.sock_len + 1 > addr.sun_path.len) return false;
        addr.sun_family = c.AF_UNIX;
        @memcpy(addr.sun_path[0..self.sock_len], self.sock_path[0..self.sock_len]);
        const fd = platform.socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return false;
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) {
            _ = c.close(fd);
            return false;
        }
        _ = c.fcntl(fd, c.F_SETFL, c.O_NONBLOCK);
        self.fd = fd;
        self.state = .ready;
        self.read_watch = c.g_unix_fd_add(
            fd,
            c.G_IO_IN | c.G_IO_HUP | c.G_IO_ERR,
            @ptrCast(&onReadable),
            self,
        );
        self.post(proto.Hello{ .proto = proto.PROTO_VERSION, .client_name = if (self.observer) "sketerm-gui-watch" else "sketerm-gui" });
        if (self.observer) {
            for (self.faces.items) |f| f.onClientReady();
            return true;
        }
        // Another window's helper: nothing is published and no view is
        // minted until `hello_ack` says it serves several clients, or
        // the views would already be sitting in its one id space when
        // the refusal arrives.
        if (self.adopted) return true;
        self.publishAfterConnect();
        return true;
    }

    /// What a fresh connection needs before its faces mint views.
    fn publishAfterConnect(self: *Client) void {
        // Re-publish every container BEFORE the faces mint their views:
        // a fresh helper knows no contexts, and a view_create naming one
        // must be preceded by its context_create. Sent optimistically
        // (before hello_ack, like view_create) — an old helper skips the
        // unknown frames and every view shares the default jar.
        publishContexts(self);
        // Extension package paths belong to this host. Remote helpers
        // intentionally receive no WebExtensions until package bytes
        // have a host-side registry/transfer protocol of their own.
        webext.ensureLoaded(self.gpa);
        // A fresh helper holds no tab table; the extensions published
        // above will ask for one on their first request.
        tabsChanged();
        for (self.faces.items) |f| f.onClientReady();
    }

    /// The connection died (helper crash, protocol error). Faces show
    /// the "helper stopped" overlay; a Reload starts a fresh one. A
    /// remote bridge records WHY it died before closing its end, so
    /// that reason (copied — teardown destroys the bridge) wins over
    /// the generic message.
    fn lost(self: *Client) void {
        if (self.state == .unavailable) return;
        self.reap();
        if (self.bridge) |br| {
            const why = br.takeReason();
            if (why.len != 0) {
                const n = @min(why.len, self.reason_buf.len);
                @memcpy(self.reason_buf[0..n], why[0..n]);
                self.fail(self.reason_buf[0..n]);
                return;
            }
        }
        self.fail(LOST_MSG);
    }

    pub fn register(self: *Client, face: *WebFace) void {
        self.faces.append(self.gpa, face) catch {};
        tabsChanged(); // MV2 onCreated
    }

    pub fn unregister(self: *Client, face: *WebFace) void {
        for (self.faces.items, 0..) |f, i| {
            if (f == face) {
                _ = self.faces.swapRemove(i);
                tabsChanged(); // MV2 onRemoved
                return;
            }
        }
    }

    pub fn findFace(self: *Client, view: u32) ?*WebFace {
        for (self.faces.items) |f| {
            if (f.view == view) return f;
        }
        return null;
    }

    /// Fetch the stored userscript + userstyle sets from the daemon
    /// web store and push them to the helper as replace-all frames.
    /// Called on every hello_ack and after every management-UI edit
    /// (src/ui/webuserscripts.zig); a helper without the capability,
    /// or a store-less daemon, degrades to "no user content".
    pub fn refreshUserContent(self: *Client) void {
        if (self.state != .ready or !self.has(.userscripts)) return;
        _ = webstore.userscriptList(self.gpa, @ptrCast(self), &onUserscriptsReply);
        _ = webstore.userstyleList(self.gpa, @ptrCast(self), &onUserstylesReply);
    }

    fn onUserscriptsReply(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
        const self = cast.userData(Client, ctx);
        if (!ok or self.state != .ready or !self.has(.userscripts)) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const list = webstore.parseUserscripts(arena.allocator(), payload);
        var scripts: std.ArrayList(proto.UsScript) = .empty;
        defer scripts.deinit(self.gpa);
        for (list) |s| {
            if (!s.enabled or s.source.len == 0) continue;
            scripts.append(self.gpa, .{
                .id = @truncate(s.id),
                .source = .{ .s = s.source },
            }) catch return;
        }
        self.post(proto.UsScriptSet{ .scripts = scripts.items });
    }

    fn onUserstylesReply(ctx: ?*anyopaque, ok: bool, payload: []const u8) void {
        const self = cast.userData(Client, ctx);
        if (!ok or self.state != .ready or !self.has(.userscripts)) return;
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const list = webstore.parseUserstyles(arena.allocator(), payload);
        var styles: std.ArrayList(proto.UsStyle) = .empty;
        defer styles.deinit(self.gpa);
        for (list, 0..) |s, i| {
            if (!s.enabled or s.css.len == 0) continue;
            styles.append(self.gpa, .{
                .id = @intCast(i + 1),
                .host = s.host,
                .css = .{ .s = s.css },
            }) catch return;
        }
        self.post(proto.UsStyleSet{ .styles = styles.items });
    }

    /// Queue a frame and push what the socket takes now. A stalled
    /// helper must never block the GLib loop, so the remainder rides a
    /// writable-fd watch.
    pub fn post(self: *Client, value: anytype) void {
        _ = self.postChecked(value);
    }

    /// Queue a frame, reporting allocation loss or a connection failure.
    pub fn postChecked(self: *Client, value: anytype) bool {
        if (self.state != .ready) return false;
        self.out.post(value, null) catch return false;
        self.flush();
        return self.state == .ready;
    }

    fn flush(self: *Client) void {
        while (self.out.front()) |m| {
            const n = c.write(self.fd, m.bytes.ptr, m.bytes.len);
            if (n < 0) {
                const e = std.c._errno().*;
                if (e == c.EAGAIN or e == c.EWOULDBLOCK) break;
                if (e == c.EINTR) continue;
                self.lost();
                return;
            }
            if (n == 0) break;
            self.out.advance(@intCast(n));
        }
        if (!self.out.empty() and self.write_watch == 0) {
            self.write_watch = c.g_unix_fd_add(
                self.fd,
                c.G_IO_OUT | c.G_IO_HUP | c.G_IO_ERR,
                @ptrCast(&onWritable),
                self,
            );
        }
    }

    fn onWritable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Client, user);
        self.write_watch = 0;
        if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
            self.lost();
            return 0;
        }
        self.flush();
        return 0;
    }

    fn onReadable(_: c_int, cond: c.GIOCondition, user: ?*anyopaque) callconv(.c) c.gboolean {
        const self = cast.userData(Client, user);
        if (cond & (c.G_IO_HUP | c.G_IO_ERR) != 0) {
            self.read_watch = 0;
            self.lost();
            return 0;
        }
        if (!self.readIn()) {
            self.read_watch = 0;
            self.lost();
            return 0;
        }
        return 1;
    }

    /// Drain the socket into `in`, collecting passed descriptors, then
    /// dispatch every complete frame. False = the connection is done.
    fn readIn(self: *Client) bool {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            var iov = c.struct_iovec{ .iov_base = &buf, .iov_len = buf.len };
            var cbuf: [64]u8 align(@alignOf(c.struct_cmsghdr)) = std.mem.zeroes([64]u8);
            var mh = std.mem.zeroes(c.struct_msghdr);
            mh.msg_iov = @ptrCast(&iov);
            mh.msg_iovlen = 1;
            mh.msg_control = &cbuf;
            mh.msg_controllen = cbuf.len;
            const n = c.recvmsg(self.fd, &mh, 0);
            if (n == 0) return false;
            if (n < 0) {
                const e = std.c._errno().*;
                if (e == c.EAGAIN or e == c.EWOULDBLOCK) break;
                if (e == c.EINTR) continue;
                return false;
            }
            const hdr_size: usize = @sizeOf(c.struct_cmsghdr);
            if (@as(usize, @intCast(mh.msg_controllen)) >= hdr_size) {
                const hdr: *const c.struct_cmsghdr = @ptrCast(@alignCast(&cbuf));
                if (hdr.cmsg_level == c.SOL_SOCKET and hdr.cmsg_type == c.SCM_RIGHTS and
                    @as(usize, @intCast(hdr.cmsg_len)) >= hdr_size + @sizeOf(c_int))
                {
                    // ONE control message can carry several descriptors:
                    // a memfd frame attaches one, a dma-buf frame one
                    // per plane. Reading only the first would leak the
                    // rest into this process forever.
                    const bytes = @as(usize, @intCast(hdr.cmsg_len)) - hdr_size;
                    var off: usize = 0;
                    while (off + @sizeOf(c_int) <= bytes and hdr_size + off + @sizeOf(c_int) <= cbuf.len) : (off += @sizeOf(c_int)) {
                        var passed: c_int = undefined;
                        @memcpy(std.mem.asBytes(&passed), cbuf[hdr_size + off ..][0..@sizeOf(c_int)]);
                        self.fds.append(self.gpa, passed) catch {
                            _ = c.close(passed);
                        };
                    }
                }
            }
            self.in.appendSlice(self.gpa, buf[0..@intCast(n)]) catch return false;
            if (@as(usize, @intCast(n)) < buf.len) break;
        }

        var reader = proto.Reader.init(self.in.items);
        while (true) {
            const frame = (reader.next() catch return false) orelse break;
            self.dispatch(frame);
            // A frame can end the connection (protocol mismatch), which
            // empties `in` underneath us.
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

    fn takeFd(self: *Client) ?c_int {
        if (self.fds.items.len == 0) return null;
        const fd = self.fds.orderedRemove(0);
        return fd;
    }

    /// Pop the `n` descriptors a frame announced, into `out`. All or
    /// nothing: a partial set is a desynchronised stream, not a frame.
    fn takeFds(self: *Client, n: usize, out: []c_int) ?[]c_int {
        if (n == 0 or n > out.len or self.fds.items.len < n) return null;
        for (out[0..n]) |*fd| fd.* = self.fds.orderedRemove(0);
        return out[0..n];
    }

    fn dispatch(self: *Client, frame: proto.Frame) void {
        switch (frame.tag) {
            .hello_ack => {
                const ack = proto.HelloAck.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ack.caps);
                if (ack.proto != proto.PROTO_VERSION) {
                    self.fail("The browser helper speaks a different protocol version.");
                    return;
                }
                self.caps = proto.parseCaps(ack.caps);
                self.sync_enabled = false;
                // Joined another window's helper: it must be able to
                // serve two clients, or our views would fight for its
                // one id space.
                if (self.adopted and !self.has(.multi_client)) {
                    self.failWith("Another sketerm window owns the browser and its helper cannot be shared (no multi-client capability). Close that window's browser pages, or restart it on this build.", false);
                    return;
                }
                // Confirmed shareable: publish what `tryConnect`
                // deferred, so the views below are minted into a helper
                // that has a window for them.
                if (self.adopted) self.publishAfterConnect();
                if (self.observer) {
                    // Nothing of this GUI's is published into an
                    // assistant's helper (see `observer`); the one
                    // thing sent is the request to be told its pages.
                    if (!self.has(.observe)) {
                        self.failWith("The assistant's browser helper is too old to be watched (no observe capability).", false);
                        return;
                    }
                    self.hello_done = true;
                    self.post(proto.ObserveEnable{ .enable = 1 });
                    for (self.faces.items) |face| face.ensureView();
                    return;
                }
                // A remote helper without inline frames would keep
                // posting memfd frames whose descriptors the bridge
                // silently ate: a black pane forever. Fail loudly now.
                if (self.isRemote() and !self.has(.frames_inline)) {
                    self.fail("The browser helper on the remote host is too old for remote browsing (no frames-inline capability).");
                    return;
                }
                self.hello_done = true;
                if (self.isRemote()) {
                    // Extension package paths belong to THIS host; a
                    // remote helper is told about none of them.
                    for ([_]proto.Cap{ .webext, .webext_tabs, .webext_action, .webext_transaction, .webext_events }) |cap|
                        self.caps.remove(cap);
                } else if (self.has(.webext)) {
                    webext.publish(self);
                    tabsChanged();
                }
                // Seed the helper with the stored user content before
                // the faces' first navigations get far.
                self.refreshUserContent();
                // One identity across every route instance: subscribe
                // the peers and seed this jar from the default one.
                cookieSyncOnReady(self);
                // The capability was unknown until this reply, so this
                // is the first point the configured set can be sent.
                publishFilterSubs(self);
                // Plain views were minted optimistically before the ack.
                // Container views wait until the strict context guarantee
                // is known, so release (or visibly refuse) those now.
                for (self.faces.items) |face| face.ensureView();
            },
            .ev_webext_state => {
                const st = proto.decode(proto.EvWebextState, frame.payload) catch return;
                webext.onState(st);
            },
            .ev_webext_install_prepared => {
                const ev = proto.decode(proto.EvWebextInstallPrepared, frame.payload) catch return;
                webext.onInstallPrepared(ev);
            },
            .ev_webext_install_committed => {
                const ev = proto.decode(proto.EvWebextInstallCommitted, frame.payload) catch return;
                webext.onInstallCommitted(ev);
            },
            .ev_webext_actions => {
                const ev = proto.decode(proto.EvWebextActions, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onWebextActions(ev.actions_json);
            },
            .ev_webext_popup => {
                const ev = proto.decode(proto.EvWebextPopup, frame.payload) catch return;
                if (self.findFace(ev.owner_view)) |face| face.onWebextPopup(ev);
            },
            .ev_webext_open_popup => {
                // Same gate as every other capability-scoped feature:
                // remote clients have `webext-action` stripped, so
                // this also keeps the old remote refusal.
                if (!self.has(.webext_action) or self.state != .ready) return;
                const ev = proto.decode(proto.EvWebextOpenPopup, frame.payload) catch return;
                const face = self.findFace(ev.view);
                const ok = if (face) |f| f.openWebextPopup(ev.id) else false;
                self.post(proto.WebextOpenPopupResult{
                    .view = ev.view,
                    .id = ev.id,
                    .req = ev.req,
                    .ok = @intFromBool(ok),
                    .detail = if (ok) "" else "active native toolbar could not create the popup",
                });
            },
            .frame_buffer => {
                const fb = proto.decode(proto.FrameBuffer, frame.payload) catch return;
                const fd = self.takeFd() orelse return;
                const face = self.findFace(fb.view) orelse {
                    for (self.faces.items) |candidate| {
                        if (candidate.adoptWebextPopupBuffer(fb, fd)) return;
                    }
                    _ = c.close(fd);
                    return;
                };
                face.adoptBuffer(fb, fd);
            },
            .frame_dmabuf => {
                const f = proto.FrameDmabuf.decodeFrom(frame.payload) catch return;
                var buf: [proto.MAX_PLANES]c_int = undefined;
                const fds = self.takeFds(f.nplanes, &buf) orelse return;
                const face = self.findFace(f.view) orelse {
                    for (fds) |fd| _ = c.close(fd);
                    return;
                };
                face.onDmabuf(f, fds);
            },
            .frame_damage => {
                const dmg = proto.FrameDamage.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(dmg.rects);
                if (self.findFace(dmg.view)) |face| {
                    face.onDamage(dmg);
                } else {
                    for (self.faces.items) |candidate| {
                        if (candidate.onWebextPopupDamage(dmg)) return;
                    }
                }
            },
            .frame_inline => {
                const fi = proto.FrameInline.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(fi.rects);
                if (self.findFace(fi.view)) |face| {
                    face.onInline(fi);
                } else {
                    for (self.faces.items) |candidate| {
                        if (candidate.onWebextPopupInline(fi)) return;
                    }
                }
            },
            .ev_title => {
                const ev = proto.decode(proto.EvTitle, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onTitle(ev.title);
            },
            .ev_observe_view => {
                const ev = proto.decode(proto.EvObserveView, frame.payload) catch return;
                if (self.observer) webwatch.onObserveView(self, ev);
            },
            .ev_observe_state => {
                const ev = proto.decode(proto.EvObserveState, frame.payload) catch return;
                if (self.observer) webwatch.onObserveState(self, ev);
            },
            .ev_nav_state => {
                const ev = proto.decode(proto.EvNavState, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onNavState(ev);
            },
            .ev_load => {
                const ev = proto.decode(proto.EvLoad, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onLoad(ev);
            },
            .ev_load_error => {
                const ev = proto.decode(proto.EvLoadError, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onLoadError(ev);
            },
            .ev_load_retry => {
                // The helper is already reloading the page on its own
                // (a local interface came or went under the engine);
                // the retried load reports through `ev_load` like any
                // other. Nothing to show: an overlay would flash for
                // the milliseconds the reload takes.
            },
            .ev_view_create_failed => {
                const ev = proto.decode(proto.EvViewCreateFailed, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onViewCreateFailed(ev);
            },
            .ev_route_refused => {
                // The route instance fails closed: every tab on it shows
                // why, and Reload starts a fresh helper that tries the
                // route again.
                const ev = proto.decode(proto.EvRouteRefused, frame.payload) catch return;
                self.fail(std.fmt.bufPrint(&self.reason_buf, "Route blocked: {s}.", .{ev.reason}) catch "Route blocked: this route's browser serves nothing.");
            },
            .ev_clipboard_text => {
                const ev = proto.decode(proto.EvClipboardText, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| {
                    if (ev.seq == face.clip_seq and ev.text.s.len > 0) face.copyText(ev.text.s);
                }
            },
            .ev_cursor => {
                const ev = proto.decode(proto.EvCursor, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onCursor(ev.cursor);
            },
            .ev_popup_request => {
                const ev = proto.decode(proto.EvPopupRequest, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onPopup(ev.url, ev.user_gesture != 0);
            },
            .ev_page_popup => {
                const ev = proto.decode(proto.EvPagePopup, frame.payload) catch return;
                if (ev.state == proto.page_popup_opened) {
                    if (self.findFace(ev.owner_view)) |face| {
                        face.onPagePopup(ev);
                    } else {
                        // Nobody to present it: the helper must not be
                        // left holding a browser nothing will close.
                        self.post(proto.ViewDestroy{ .view = ev.popup_view });
                    }
                } else if (self.findFace(ev.popup_view)) |face| {
                    // The popup closed itself, which is how every OAuth
                    // flow ends. Retire its tab or popup window whole;
                    // `closeSelf` ignores a face the engine did not open.
                    face.closeSelf();
                }
            },
            .ev_cert_error => {
                const ev = proto.decode(proto.EvCertError, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onCertError(ev);
            },
            .ev_permission => {
                const ev = proto.decode(proto.EvPermission, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onPermission(ev);
            },
            .ev_find_result => {
                const ev = proto.decode(proto.EvFindResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onFindResult(ev);
            },
            .ev_context_menu => {
                const ev = proto.decode(proto.EvContextMenu, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onContextMenu(ev);
            },
            .ev_crashed => {
                const ev = proto.decode(proto.EvCrashed, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onCrashed();
            },
            .ev_a11y_tree => {
                const ev = proto.decode(proto.EvA11yTree, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onAxTree(ev);
            },
            .ev_a11y_loc => {
                const ev = proto.decode(proto.EvA11yLoc, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onAxLoc(ev);
            },
            .ev_a11y_caret => {
                const ev = proto.decode(proto.EvA11yCaret, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onAxCaret(ev);
            },
            .ev_a11y_event => {
                const ev = proto.decode(proto.EvA11yEvent, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onAxEvent(ev);
            },
            .sem_result => {
                const result = proto.decode(proto.SemResult, frame.payload) catch return;
                self.dispatchSemantic(proto.semResultUnwrap(result), result.request);
            },
            .sem_snapshot, .sem_act_result, .sem_expand_result, .sem_query_result, .sem_read_result, .sem_read_ids_result, .sem_eval_result => self.dispatchSemantic(frame, 0),
            .intercept_status => {
                const ev = proto.decode(proto.InterceptStatus, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onInterceptStatus(ev);
            },
            .intercept_log => {
                const ev = proto.InterceptLog.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ev.entries);
                if (self.findFace(ev.view)) |face| face.onInterceptLog(ev);
            },
            .ev_devtools_view => {
                const ev = proto.decode(proto.EvDevToolsView, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| {
                    face.onDevToolsView(ev.devtools, ev.reason);
                } else if (ev.devtools != 0) {
                    // The pane that asked is gone; the inspector it
                    // would have shown must not stay alive on the
                    // helper with nobody able to close it.
                    self.post(proto.ViewDestroy{ .view = ev.devtools });
                }
            },
            .ev_print_pdf_done => {
                const ev = proto.decode(proto.EvPrintPdfDone, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onPrintDone(ev);
            },
            .ev_download_offer => {
                const ev = proto.decode(proto.EvDownloadOffer, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| {
                    face.onDownloadOffer(ev);
                } else {
                    // A held decision must always be answered; the pane
                    // that would ask is gone.
                    self.post(proto.DownloadDecide{ .view = ev.view, .id = ev.id, .path = "" });
                }
            },
            .ev_cookie_change => {
                const ev = proto.EvCookieChange.decodeFrom(frame.payload) catch return;
                onCookieChange(self, ev);
            },
            .ev_cookie_dump => {
                const ev = proto.EvCookieDump.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ev.cookies);
                onCookieDump(self, ev);
            },
            .ev_cookies => {
                const ev = proto.EvCookies.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ev.entries);
                if (self.findFace(ev.view)) |face| face.onCookies(ev);
            },
            .ev_sitedata_done => {
                const ev = proto.decode(proto.EvSitedataDone, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onSitedataDone(ev);
            },
            .ev_download_progress => {
                const ev = proto.decode(proto.EvDownloadProgress, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onDownloadProgress(ev);
            },
            .ev_scroll => {
                const ev = proto.decode(proto.EvScroll, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| {
                    face.scroll_x = ev.x;
                    face.scroll_y = ev.y;
                }
            },
            else => {},
        }
    }

    fn dispatchSemantic(self: *Client, frame: proto.Frame, request: u32) void {
        switch (frame.tag) {
            .sem_snapshot => {
                const ev = proto.decode(proto.SemSnapshot, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onSnapshot(ev, request);
            },
            .sem_act_result => {
                const ev = proto.decode(proto.SemActResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.completeOp(.act, request, ev.ok != 0, ev.msg, .{});
            },
            .sem_expand_result => {
                const ev = proto.decode(proto.SemExpandResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.completeOp(.expand, request, true, ev.text, .{});
            },
            .sem_query_result => {
                const ev = proto.decode(proto.SemQueryResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| {
                    if (!face.onHintsResult(request, ev.payload.s))
                        face.completeOp(.query, request, true, ev.payload.s, .{});
                }
            },
            .sem_read_result => {
                const ev = proto.decode(proto.SemReadResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| {
                    face.completeOp(.read, request, true, ev.markdown.s, .{});
                    face.onReadReply();
                }
            },
            .sem_read_ids_result => {
                const ev = proto.SemReadIdsResult.decodeAlloc(frame.payload, self.gpa) catch return;
                defer self.gpa.free(ev.entities);
                if (self.findFace(ev.view)) |face| {
                    face.onReadIds(ev, request);
                    face.onReadReply();
                }
            },
            .sem_eval_result => {
                const ev = proto.decode(proto.SemEvalResult, frame.payload) catch return;
                if (self.findFace(ev.view)) |face| face.onEvalResult(ev, request);
            },
            else => {},
        }
    }
};
