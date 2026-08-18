//! Per-session AT-SPI accessibility bridge, daemon-side so it works
//! wherever the session runs (local or SSH/UDP remote — the daemon
//! is always on the app's machine). Spawns a private D-Bus session
//! bus for the app; the app auto-activates org.a11y.Bus on it, so
//! GTK/Qt publish their widget tree there. On demand the daemon
//! connects as a pure-Zig D-Bus client (mux/dbus.zig — no libdbus,
//! musl-clean) and serializes the tree to JSON for the MCP layer.
//!
//! Degrades gracefully: if dbus-daemon is missing the session still
//! runs, just without an a11y tree.

const std = @import("std");
const c = @import("../c.zig").c;
const dbus = @import("dbus.zig");

const nowMs = @import("../util/clock.zig").nowMs;

const ATSPI_ACCESSIBLE = "org.a11y.atspi.Accessible";
const ATSPI_REGISTRY_DEST = "org.a11y.atspi.Registry";
const REGISTRY_ROOT = "/org/a11y/atspi/accessible/root";
const MAX_NODES = 4000;
const MAX_DEPTH = 40;

pub const Hub = struct {
    allocator: std.mem.Allocator,
    /// Session bus socket path (also the child's
    /// DBUS_SESSION_BUS_ADDRESS = "unix:path=<this>").
    bus_path: []u8,
    /// NUL-terminated "unix:path=..." for env export.
    bus_addr_z: [:0]u8,
    dbus_pid: c_int = -1,
    /// at-spi2-registryd, started BEFORE the app so its GTK/Qt a11y
    /// init finds the registry and publishes its tree (the registry's
    /// on-demand systemd activation is unreliable in a bare session).
    registry_pid: c_int = -1,
    /// org.a11y.Status.IsEnabled was set (apps told to publish).
    enabled: bool = false,

    /// Create the private session bus. `dir` is the session aux dir
    /// (same place the Wayland socket lives), `id` disambiguates.
    /// Null if dbus-daemon is unavailable / spawn failed.
    /// Private XDG_RUNTIME_DIR for the a11y bus processes, so
    /// at-spi-bus-launcher's a11y-bus socket (derived from
    /// XDG_RUNTIME_DIR) is per-session, not shared. Removed on
    /// teardown.
    rt_dir: ?[:0]u8 = null,

    pub fn setup(allocator: std.mem.Allocator, dir: []const u8, id: []const u8) ?Hub {
        const bus_path = std.fmt.allocPrint(allocator, "{s}/dbus-{s}", .{ dir, id }) catch return null;
        var ok = false;
        defer if (!ok) allocator.free(bus_path);

        // Private runtime dir for the bus processes' a11y socket.
        const rt_dir = std.fmt.allocPrintSentinel(allocator, "{s}/a11y-{s}", .{ dir, id }, 0) catch return null;
        var ok_rt = false;
        defer if (!ok_rt) allocator.free(rt_dir);
        _ = c.mkdir(rt_dir.ptr, 0o700);

        var zbuf: [4096]u8 = undefined;
        if (bus_path.len + 1 > zbuf.len) return null;
        @memcpy(zbuf[0..bus_path.len], bus_path);
        zbuf[bus_path.len] = 0;
        _ = c.unlink(@ptrCast(&zbuf));

        const addr_z = std.fmt.allocPrintSentinel(allocator, "unix:path={s}", .{bus_path}, 0) catch return null;
        var ok2 = false;
        defer if (!ok2) allocator.free(addr_z);

        // Fork + exec dbus-daemon bound to our address. --nofork so
        // the pid we get IS the bus (killable on teardown).
        const pid = c.fork();
        if (pid < 0) return null;
        if (pid == 0) {
            // Child: silence output, exec the bus.
            const devnull = c.open("/dev/null", c.O_WRONLY);
            if (devnull >= 0) {
                _ = c.dup2(devnull, 1);
                _ = c.dup2(devnull, 2);
            }
            _ = c.setenv("XDG_RUNTIME_DIR", rt_dir.ptr, 1);
            var abuf: [4096]u8 = undefined;
            const a = std.fmt.bufPrintZ(&abuf, "--address=unix:path={s}", .{bus_path}) catch c.abort();
            const argv = [_:null]?[*:0]const u8{
                "dbus-daemon", "--session", "--nofork", "--nopidfile", a.ptr, null,
            };
            _ = c.execvp("dbus-daemon", @ptrCast(&argv));
            c._exit(127);
        }

        // Wait (bounded) for the bus socket to appear.
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            if (c.access(@ptrCast(&zbuf), c.F_OK) == 0) break;
            // Reap an early-exiting dbus-daemon (missing binary).
            var st: c_int = 0;
            if (c.waitpid(pid, &st, c.WNOHANG) == pid) {
                return null;
            }
            var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 10 * 1000 * 1000 };
            _ = c.nanosleep(&ts, null);
        }
        if (c.access(@ptrCast(&zbuf), c.F_OK) != 0) {
            _ = c.kill(pid, c.SIGTERM);
            return null;
        }

        // Start the AT-SPI registry on this bus now, so the app's
        // toolkit a11y init (at startup) finds it and registers. Its
        // env DBUS_SESSION_BUS_ADDRESS must be OUR session bus; it
        // discovers the a11y bus itself via org.a11y.Bus.
        const reg_pid = spawnRegistry(addr_z, rt_dir);

        var hub = Hub{
            .allocator = allocator,
            .bus_path = bus_path,
            .bus_addr_z = addr_z,
            .dbus_pid = pid,
            .registry_pid = reg_pid,
            .rt_dir = rt_dir,
        };
        // Block (bounded) until the registry owns its name on the
        // a11y bus, so the app we're about to spawn finds it at
        // startup and publishes its tree. Toolkits don't retry a11y
        // registration, so this ordering is load-bearing.
        if (reg_pid > 0) hub.waitRegistryReady(2_500);
        // Announce accessibility ON before the app initializes —
        // GTK/Qt check org.a11y.Status.IsEnabled at startup and only
        // build their tree when it's set.
        hub.enableStatus();

        ok = true;
        ok2 = true;
        ok_rt = true;
        return hub;
    }

    /// Poll the a11y bus until org.a11y.atspi.Registry is reachable
    /// or `budget_ms` elapses.
    fn waitRegistryReady(self: *Hub, budget_ms: i64) void {
        const deadline = nowMs() + budget_ms;
        while (nowMs() < deadline) {
            if (self.registryOwned()) return;
            var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000 };
            _ = c.nanosleep(&ts, null);
        }
    }

    /// Set org.a11y.Status IsEnabled + ScreenReaderEnabled on the
    /// session bus (best-effort).
    fn enableStatus(self: *Hub) void {
        var sess = Conn.connect(self.allocator, self.bus_path) catch return;
        defer sess.deinit();
        sess.authAndHello() catch return;
        setStatus(self.allocator, &sess, "IsEnabled", true) catch {};
        setStatus(self.allocator, &sess, "ScreenReaderEnabled", true) catch {};
        self.enabled = true;
    }

    fn registryOwned(self: *Hub) bool {
        const a = self.allocator;
        var sess = Conn.connect(a, self.bus_path) catch return false;
        defer sess.deinit();
        sess.authAndHello() catch return false;
        const ga = sess.call(.{
            .mtype = .method_call,
            .path = "/org/a11y/bus",
            .interface = "org.a11y.Bus",
            .member = "GetAddress",
            .destination = "org.a11y.Bus",
        }) catch return false;
        defer a.free(ga.body);
        var gr = dbus.Reader.init(ga.body);
        const a11y_addr = gr.string() catch return false;
        const a11y_path = parseUnixPath(a11y_addr) orelse return false;
        var bus = Conn.connect(a, a11y_path) catch return false;
        defer bus.deinit();
        bus.authAndHello() catch return false;
        // NameHasOwner(org.a11y.atspi.Registry) on the a11y bus.
        var bw = dbus.Writer.init(a);
        defer bw.deinit();
        bw.putString("org.a11y.atspi.Registry") catch return false;
        const r = bus.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "NameHasOwner",
            .destination = "org.freedesktop.DBus",
            .signature = "s",
            .body = bw.buf.items,
        }) catch return false;
        defer a.free(r.body);
        var rd = dbus.Reader.init(r.body);
        return (rd.u32v() catch 0) != 0;
    }

    /// Fork + exec at-spi2-registryd against session bus `addr`
    /// ("unix:path=..."). Not on $PATH — try the usual install dirs.
    /// Returns -1 if none exists (a11y then just yields empty trees).
    fn spawnRegistry(addr: [:0]const u8, rt_dir: [:0]const u8) c_int {
        const candidates = [_][*:0]const u8{
            "/usr/lib/at-spi2-registryd",
            "/usr/libexec/at-spi2-registryd",
            "/usr/lib/at-spi2-core/at-spi2-registryd",
            "/usr/lib64/at-spi2-registryd",
        };
        const pid = c.fork();
        if (pid < 0) return -1;
        if (pid == 0) {
            const devnull = c.open("/dev/null", c.O_WRONLY);
            if (devnull >= 0) {
                _ = c.dup2(devnull, 1);
                _ = c.dup2(devnull, 2);
            }
            _ = c.setenv("DBUS_SESSION_BUS_ADDRESS", addr.ptr, 1);
            _ = c.setenv("ATSPI_DBUS_IMPLEMENTATION", "dbus-daemon", 1);
            _ = c.setenv("XDG_RUNTIME_DIR", rt_dir.ptr, 1);
            const argv = [_:null]?[*:0]const u8{ "at-spi2-registryd", null };
            for (candidates) |path| _ = c.execv(path, @ptrCast(&argv));
            c._exit(127);
        }
        return pid;
    }

    pub fn deinit(self: *Hub) void {
        var st: c_int = 0;
        if (self.registry_pid > 0) {
            _ = c.kill(self.registry_pid, c.SIGTERM);
            _ = c.waitpid(self.registry_pid, &st, 0);
        }
        if (self.dbus_pid > 0) {
            _ = c.kill(self.dbus_pid, c.SIGTERM);
            _ = c.waitpid(self.dbus_pid, &st, 0);
        }
        var zbuf: [4096]u8 = undefined;
        if (self.bus_path.len + 1 <= zbuf.len) {
            @memcpy(zbuf[0..self.bus_path.len], self.bus_path);
            zbuf[self.bus_path.len] = 0;
            _ = c.unlink(@ptrCast(&zbuf));
        }
        if (self.rt_dir) |dir| {
            removeA11yTree(dir);
            self.allocator.free(dir);
        }
        self.allocator.free(self.bus_path);
        self.allocator.free(self.bus_addr_z);
    }

    /// Removes the private a11y runtime tree without forking after EGL init.
    fn removeA11yTree(dir: []const u8) void {
        var zbuf: [4096]u8 = undefined;
        const zdir = std.fmt.bufPrintZ(&zbuf, "{s}", .{dir}) catch return;
        if (c.opendir(zdir.ptr)) |dp| {
            while (c.readdir(dp)) |entry| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                var child_buf: [4096]u8 = undefined;
                const child = std.fmt.bufPrintZ(&child_buf, "{s}/{s}", .{ dir, name }) catch continue;
                if (c.unlinkat(c.AT_FDCWD, child.ptr, 0) != 0) {
                    removeA11yTree(child);
                    _ = c.unlinkat(c.AT_FDCWD, child.ptr, c.AT_REMOVEDIR);
                }
            }
            _ = c.closedir(dp);
        }
        _ = c.rmdir(zdir.ptr);
    }

    /// Connect to the a11y bus and serialize the tree from the
    /// registry root to JSON (arena/caller-owned). Null on any
    /// failure (bus down, no apps registered, toolkit without AT-SPI).
    /// Connect to the session's a11y bus (enabling toolkit a11y on
    /// first use). Caller deinits the returned Conn.
    fn openA11yBus(self: *Hub, allocator: std.mem.Allocator) ?Conn {
        var sess = Conn.connect(allocator, self.bus_path) catch return null;
        defer sess.deinit();
        sess.authAndHello() catch return null;

        // GTK/Qt build their AT-SPI tree lazily — only once an
        // assistive tech signals interest via org.a11y.Status. Set
        // IsEnabled + ScreenReaderEnabled = true so the apps publish;
        // give newly-notified apps a moment on the first enable.
        const first_enable = !self.enabled;
        setStatus(allocator, &sess, "IsEnabled", true) catch {};
        setStatus(allocator, &sess, "ScreenReaderEnabled", true) catch {};
        self.enabled = true;
        if (first_enable) {
            var ts = c.struct_timespec{ .tv_sec = 0, .tv_nsec = 600 * 1000 * 1000 };
            _ = c.nanosleep(&ts, null);
        }

        // org.a11y.Bus.GetAddress on the session bus → a11y bus.
        const ga = sess.call(.{
            .mtype = .method_call,
            .path = "/org/a11y/bus",
            .interface = "org.a11y.Bus",
            .member = "GetAddress",
            .destination = "org.a11y.Bus",
        }) catch return null;
        defer allocator.free(ga.body);
        var gr = dbus.Reader.init(ga.body);
        const a11y_addr = gr.string() catch return null;
        const a11y_path = parseUnixPath(a11y_addr) orelse return null;

        var bus = Conn.connect(allocator, a11y_path) catch return null;
        bus.authAndHello() catch {
            bus.deinit();
            return null;
        };
        return bus;
    }

    pub fn treeJson(self: *Hub, allocator: std.mem.Allocator) ?[]u8 {
        var bus = self.openA11yBus(allocator) orelse return null;
        defer bus.deinit();

        // No errdefer: this returns `?[]u8`, so one would never run.
        // Every failure below releases `out` explicitly.
        var out: std.ArrayList(u8) = .empty;
        var w = Walker{ .allocator = allocator, .conn = &bus, .out = &out, .count = 0 };
        w.node(ATSPI_REGISTRY_DEST, REGISTRY_ROOT, 0) catch {
            out.deinit(allocator);
            return null;
        };
        return out.toOwnedSlice(allocator) catch {
            out.deinit(allocator);
            return null;
        };
    }

    /// org.a11y.atspi.Action.DoAction(index) on the node `id` (a tree
    /// "id" value). Index 0 is the toolkit's default action (press /
    /// activate / toggle). False on any failure.
    pub fn doAction(self: *Hub, allocator: std.mem.Allocator, id: []const u8, index: i32) bool {
        var path_buf: [256]u8 = undefined;
        const ref = splitId(id, &path_buf) orelse return false;
        var bus = self.openA11yBus(allocator) orelse return false;
        defer bus.deinit();
        var bw = dbus.Writer.init(allocator);
        defer bw.deinit();
        bw.putI32(index) catch return false;
        const r = bus.call(.{
            .mtype = .method_call,
            .path = ref.path,
            .interface = "org.a11y.atspi.Action",
            .member = "DoAction",
            .destination = ref.dest,
            .signature = "i",
            .body = bw.buf.items,
        }) catch return false;
        allocator.free(r.body);
        return true;
    }

    /// org.a11y.atspi.EditableText.SetTextContents on node `id` —
    /// replaces a text field's whole content. False on failure (node
    /// not editable, gone, ...).
    pub fn setTextContents(self: *Hub, allocator: std.mem.Allocator, id: []const u8, text: []const u8) bool {
        var path_buf: [256]u8 = undefined;
        const ref = splitId(id, &path_buf) orelse return false;
        var bus = self.openA11yBus(allocator) orelse return false;
        defer bus.deinit();
        var bw = dbus.Writer.init(allocator);
        defer bw.deinit();
        bw.putString(text) catch return false;
        const r = bus.call(.{
            .mtype = .method_call,
            .path = ref.path,
            .interface = "org.a11y.atspi.EditableText",
            .member = "SetTextContents",
            .destination = ref.dest,
            .signature = "s",
            .body = bw.buf.items,
        }) catch return false;
        allocator.free(r.body);
        return true;
    }

    /// org.a11y.atspi.Text state of node `id`: full text (owned by the
    /// caller) + caret offset in characters. Null when the node has no
    /// Text interface or the bus is down.
    pub const TextState = struct { text: []u8, caret: i32 };

    pub fn textState(self: *Hub, allocator: std.mem.Allocator, id: []const u8) ?TextState {
        var path_buf: [256]u8 = undefined;
        const ref = splitId(id, &path_buf) orelse return null;
        var bus = self.openA11yBus(allocator) orelse return null;
        defer bus.deinit();
        const count = textIntProp(allocator, &bus, ref, "CharacterCount") orelse return null;
        var bw = dbus.Writer.init(allocator);
        defer bw.deinit();
        bw.putI32(0) catch return null;
        bw.putI32(count) catch return null;
        const r = bus.call(.{
            .mtype = .method_call,
            .path = ref.path,
            .interface = "org.a11y.atspi.Text",
            .member = "GetText",
            .destination = ref.dest,
            .signature = "ii",
            .body = bw.buf.items,
        }) catch return null;
        defer allocator.free(r.body);
        var rd = dbus.Reader.init(r.body);
        const s = rd.string() catch return null;
        const text = allocator.dupe(u8, s) catch return null;
        const caret = textIntProp(allocator, &bus, ref, "CaretOffset") orelse {
            allocator.free(text);
            return null;
        };
        return .{ .text = text, .caret = caret };
    }

    /// org.a11y.atspi.Text.GetNSelections on node `id`. Null on failure.
    pub fn textNSelections(self: *Hub, allocator: std.mem.Allocator, id: []const u8) ?i32 {
        var path_buf: [256]u8 = undefined;
        const ref = splitId(id, &path_buf) orelse return null;
        var bus = self.openA11yBus(allocator) orelse return null;
        defer bus.deinit();
        const r = bus.call(.{
            .mtype = .method_call,
            .path = ref.path,
            .interface = "org.a11y.atspi.Text",
            .member = "GetNSelections",
            .destination = ref.dest,
        }) catch return null;
        defer allocator.free(r.body);
        var rd = dbus.Reader.init(r.body);
        return rd.i32v() catch null;
    }

    /// org.a11y.atspi.Text.GetSelection(0) on node `id` → [start, end)
    /// character offsets. Null when there is no selection.
    pub fn textSelection(self: *Hub, allocator: std.mem.Allocator, id: []const u8) ?[2]i32 {
        var path_buf: [256]u8 = undefined;
        const ref = splitId(id, &path_buf) orelse return null;
        var bus = self.openA11yBus(allocator) orelse return null;
        defer bus.deinit();
        var bw = dbus.Writer.init(allocator);
        defer bw.deinit();
        bw.putI32(0) catch return null;
        const r = bus.call(.{
            .mtype = .method_call,
            .path = ref.path,
            .interface = "org.a11y.atspi.Text",
            .member = "GetSelection",
            .destination = ref.dest,
            .signature = "i",
            .body = bw.buf.items,
        }) catch return null;
        defer allocator.free(r.body);
        var rd = dbus.Reader.init(r.body);
        const a = rd.i32v() catch return null;
        const b = rd.i32v() catch return null;
        return .{ a, b };
    }

    /// Listen for AT-SPI object events on the a11y bus. This is the
    /// only way to prove a provider EMITTED something rather than
    /// merely being willing to answer a poll, which is the whole
    /// difference between a reader being told and a reader re-walking.
    /// Caller deinits.
    pub fn watchEvents(self: *Hub, allocator: std.mem.Allocator) ?EventWatch {
        // `?EventWatch`, so an errdefer would never run: both bail-outs
        // close the bus by hand. Leaking it here leaked the connection
        // AND its socket fd, and a few retries exhausted the daemon's
        // fd table.
        var bus = self.openA11yBus(allocator) orelse return null;
        var bw = dbus.Writer.init(allocator);
        defer bw.deinit();
        bw.putString("type='signal',interface='org.a11y.atspi.Event.Object'") catch {
            bus.deinit();
            return null;
        };
        const r = bus.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "AddMatch",
            .destination = "org.freedesktop.DBus",
            .signature = "s",
            .body = bw.buf.items,
        }) catch {
            bus.deinit();
            return null;
        };
        allocator.free(r.body);
        return .{ .conn = bus, .allocator = allocator };
    }

    pub const EventWatch = struct {
        conn: Conn,
        allocator: std.mem.Allocator,

        /// One received signal, copied into fixed buffers so the
        /// caller never holds a slice into the read buffer.
        pub const Event = struct {
            member_buf: [64]u8 = @splat(0),
            member_len: usize = 0,
            detail_buf: [64]u8 = @splat(0),
            detail_len: usize = 0,
            path_buf: [128]u8 = @splat(0),
            path_len: usize = 0,
            detail1: i32 = 0,
            detail2: i32 = 0,

            pub fn member(self: *const Event) []const u8 {
                return self.member_buf[0..self.member_len];
            }
            pub fn detail(self: *const Event) []const u8 {
                return self.detail_buf[0..self.detail_len];
            }
            pub fn path(self: *const Event) []const u8 {
                return self.path_buf[0..self.path_len];
            }
        };

        pub fn deinit(self: *EventWatch) void {
            self.conn.deinit();
        }

        /// Next object event, or null on timeout. Non-signal traffic
        /// is discarded.
        pub fn next(self: *EventWatch, timeout_ms: i64) ?Event {
            const deadline = nowMs() + timeout_ms;
            while (true) {
                while (dbus.unmarshal(self.conn.rbuf.items) catch return null) |got| {
                    const m = got.msg;
                    var ev: ?Event = null;
                    if (m.mtype == .signal) ev = decodeEvent(m);
                    self.conn.rbuf.replaceRange(self.allocator, 0, got.consumed, &.{}) catch return null;
                    if (ev) |e| return e;
                }
                self.conn.waitFd(c.POLLIN, deadline) catch return null;
                var tmp: [8192]u8 = undefined;
                const n = c.read(self.conn.fd, &tmp, tmp.len);
                if (n > 0) {
                    self.conn.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]) catch return null;
                    continue;
                }
                if (n == 0) return null;
                const e = std.posix.errno(n);
                if (e == .INTR or e == .AGAIN) continue;
                return null;
            }
        }

        fn decodeEvent(m: dbus.Message) ?Event {
            var ev = Event{};
            const mem = m.member orelse return null;
            const p = m.path orelse "";
            if (mem.len > ev.member_buf.len or p.len > ev.path_buf.len) return null;
            @memcpy(ev.member_buf[0..mem.len], mem);
            ev.member_len = mem.len;
            @memcpy(ev.path_buf[0..p.len], p);
            ev.path_len = p.len;
            // Body is siiv a{sv}; only the first three are needed here.
            var rd = dbus.Reader.init(m.body);
            const d = rd.string() catch return ev;
            if (d.len <= ev.detail_buf.len) {
                @memcpy(ev.detail_buf[0..d.len], d);
                ev.detail_len = d.len;
            }
            ev.detail1 = rd.i32v() catch return ev;
            ev.detail2 = rd.i32v() catch return ev;
            return ev;
        }
    };

    /// Set org.a11y.atspi.Value.CurrentValue (sliders, spinners,
    /// scrollbars) on node `id`. False on failure.
    pub fn setCurrentValue(self: *Hub, allocator: std.mem.Allocator, id: []const u8, value: f64) bool {
        var path_buf: [256]u8 = undefined;
        const ref = splitId(id, &path_buf) orelse return false;
        var bus = self.openA11yBus(allocator) orelse return false;
        defer bus.deinit();
        var bw = dbus.Writer.init(allocator);
        defer bw.deinit();
        bw.putString("org.a11y.atspi.Value") catch return false;
        bw.putString("CurrentValue") catch return false;
        bw.putSig("d") catch return false;
        bw.putF64(value) catch return false;
        const r = bus.call(.{
            .mtype = .method_call,
            .path = ref.path,
            .interface = "org.freedesktop.DBus.Properties",
            .member = "Set",
            .destination = ref.dest,
            .signature = "ssv",
            .body = bw.buf.items,
        }) catch return false;
        allocator.free(r.body);
        return true;
    }
};

/// Standard AT-SPI object-path prefix; node ids compress it away.
const ATSPI_PATH_PREFIX = "/org/a11y/atspi/accessible/";

/// Compose a compact node id from a (dest, path) pair: "<dest>#<tail>"
/// where tail is the path with the standard prefix stripped (full
/// paths that don't match keep their leading '/').
fn makeId(out: *std.ArrayList(u8), a: std.mem.Allocator, dest: []const u8, path: []const u8) !void {
    try out.appendSlice(a, dest);
    try out.append(a, '#');
    if (std.mem.startsWith(u8, path, ATSPI_PATH_PREFIX)) {
        try out.appendSlice(a, path[ATSPI_PATH_PREFIX.len..]);
    } else {
        try out.appendSlice(a, path);
    }
}

const IdRef = struct { dest: []const u8, path: []const u8 };

/// Parse a node id back into (dest, path). `path_buf` backs a
/// reconstructed standard path.
fn splitId(id: []const u8, path_buf: *[256]u8) ?IdRef {
    const hash = std.mem.indexOfScalar(u8, id, '#') orelse return null;
    const dest = id[0..hash];
    const tail = id[hash + 1 ..];
    if (dest.len == 0 or tail.len == 0) return null;
    if (tail[0] == '/') return .{ .dest = dest, .path = tail };
    const p = std.fmt.bufPrint(path_buf, ATSPI_PATH_PREFIX ++ "{s}", .{tail}) catch return null;
    return .{ .dest = dest, .path = p };
}

/// Read an i32 org.a11y.atspi.Text property (CharacterCount,
/// CaretOffset) off node `ref`. Null when absent or not an int.
fn textIntProp(allocator: std.mem.Allocator, conn: *Conn, ref: IdRef, prop: []const u8) ?i32 {
    var bw = dbus.Writer.init(allocator);
    defer bw.deinit();
    bw.putString("org.a11y.atspi.Text") catch return null;
    bw.putString(prop) catch return null;
    const r = conn.call(.{
        .mtype = .method_call,
        .path = ref.path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Get",
        .destination = ref.dest,
        .signature = "ss",
        .body = bw.buf.items,
    }) catch return null;
    defer allocator.free(r.body);
    var rd = dbus.Reader.init(r.body);
    const vsig = rd.sig() catch return null;
    if (vsig.len != 1 or vsig[0] != 'i') return null;
    return rd.i32v() catch null;
}

/// Set a boolean org.a11y.Status property on /org/a11y/bus (session
/// bus) via org.freedesktop.DBus.Properties.Set(ssv). This is how an
/// AT tells toolkits "accessibility is on, publish your tree".
fn setStatus(allocator: std.mem.Allocator, conn: *Conn, prop: []const u8, val: bool) !void {
    var bw = dbus.Writer.init(allocator);
    defer bw.deinit();
    try bw.putString("org.a11y.Status");
    try bw.putString(prop);
    try bw.putSig("b"); // variant signature
    try bw.putBool(val);
    const r = try conn.call(.{
        .mtype = .method_call,
        .path = "/org/a11y/bus",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .destination = "org.a11y.Bus",
        .signature = "ssv",
        .body = bw.buf.items,
    });
    allocator.free(r.body);
}

/// "unix:path=/x,guid=..." or ",abstract=..." → connect target
/// ('@'-prefixed for the abstract namespace). Returned slice points
/// into `addr` unless abstract (then it's a static-buf copy — the
/// caller connects immediately, before the buf is reused).
fn parseUnixPath(addr: []const u8) ?[]const u8 {
    var seg = std.mem.splitScalar(u8, addr, ';');
    const first = seg.next() orelse return null;
    if (!std.mem.startsWith(u8, first, "unix:")) return null;
    var kv = std.mem.splitScalar(u8, first["unix:".len..], ',');
    while (kv.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "path=")) return pair["path=".len..];
        if (std.mem.startsWith(u8, pair, "abstract=")) {
            abstract_buf[0] = '@';
            const v = pair["abstract=".len..];
            if (v.len + 1 > abstract_buf.len) return null;
            @memcpy(abstract_buf[1 .. 1 + v.len], v);
            return abstract_buf[0 .. 1 + v.len];
        }
    }
    return null;
}
var abstract_buf: [256]u8 = undefined;

// ── D-Bus client over a Unix socket (c.zig sockets) ─────────────

const Conn = struct {
    fd: c_int,
    serial: u32 = 1,
    rbuf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    /// Total budget for this connection/operation, not a fresh timeout per
    /// tree node. A peer replying just before every per-call timeout must
    /// not monopolize the daemon for MAX_NODES × timeout.
    deadline_ms: i64,

    fn connect(allocator: std.mem.Allocator, path: []const u8) !Conn {
        const fd = @import("../util/platform.zig").socketCloexec(c.AF_UNIX, c.SOCK_STREAM, 0);
        if (fd < 0) return error.Socket;
        errdefer _ = c.close(fd);
        var addr: c.struct_sockaddr_un = std.mem.zeroes(c.struct_sockaddr_un);
        addr.sun_family = c.AF_UNIX;
        const dst = std.mem.asBytes(&addr.sun_path);
        if (path.len == 0 or path.len >= dst.len) return error.BadPath;
        if (path[0] == '@') {
            dst[0] = 0; // abstract namespace
            @memcpy(dst[1..path.len], path[1..]);
        } else {
            @memcpy(dst[0..path.len], path);
        }
        if (c.connect(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_un)) != 0) return error.Connect;
        const fl = c.fcntl(fd, c.F_GETFL, @as(c_int, 0));
        if (fl >= 0) _ = c.fcntl(fd, c.F_SETFL, fl | c.O_NONBLOCK);
        // Budget sized for a full MAX_NODES tree walk (thousands of local
        // D-Bus round trips) on a healthy bus, while still bounding how
        // long a wedged peer can stall the daemon poll loop.
        return .{ .fd = fd, .allocator = allocator, .deadline_ms = nowMs() + 30_000 };
    }

    fn deinit(self: *Conn) void {
        _ = c.close(self.fd);
        self.rbuf.deinit(self.allocator);
    }

    fn waitFd(self: *Conn, events: c_short, deadline: i64) !void {
        while (true) {
            const left: c_int = @intCast(@max(0, @min(deadline - nowMs(), std.math.maxInt(c_int))));
            if (left == 0) return error.Timeout;
            var pfd = c.struct_pollfd{ .fd = self.fd, .events = events, .revents = 0 };
            const rc = c.poll(&pfd, 1, left);
            if (rc > 0 and pfd.revents & events != 0) return;
            if (rc < 0 and std.posix.errno(rc) == .INTR) continue;
            if (rc == 0) return error.Timeout;
            return error.Closed;
        }
    }

    fn writeAll(self: *Conn, bytes: []const u8) !void {
        const deadline = self.deadline_ms;
        var off: usize = 0;
        while (off < bytes.len) {
            const n = c.write(self.fd, bytes[off..].ptr, bytes.len - off);
            if (n > 0) {
                off += @intCast(n);
                continue;
            }
            const e = std.posix.errno(n);
            if (e == .INTR) continue;
            if (e == .AGAIN) {
                try self.waitFd(c.POLLOUT, deadline);
                continue;
            }
            return error.Write;
        }
    }

    /// SASL EXTERNAL auth (uid as decimal, hex-encoded) + BEGIN, then
    /// the org.freedesktop.DBus.Hello handshake.
    fn authAndHello(self: *Conn) !void {
        try self.writeAll(&.{0});
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        try line.appendSlice(self.allocator, "AUTH EXTERNAL ");
        var idbuf: [32]u8 = undefined;
        const dec = try std.fmt.bufPrint(&idbuf, "{d}", .{c.getuid()});
        for (dec) |ch| {
            var h: [2]u8 = undefined;
            _ = std.fmt.bufPrint(&h, "{x:0>2}", .{ch}) catch unreachable;
            try line.appendSlice(self.allocator, &h);
        }
        try line.appendSlice(self.allocator, "\r\n");
        try self.writeAll(line.items);
        var buf: [256]u8 = undefined;
        try self.waitFd(c.POLLIN, self.deadline_ms);
        const n = c.read(self.fd, &buf, buf.len);
        if (n <= 0) return error.AuthRead;
        if (!std.mem.startsWith(u8, buf[0..@intCast(n)], "OK")) return error.AuthRejected;
        try self.writeAll("BEGIN\r\n");
        const r = try self.call(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "Hello",
            .destination = "org.freedesktop.DBus",
        });
        self.allocator.free(r.body);
    }

    /// Send one method call, return the matching reply (body is
    /// caller-owned). Signals / unrelated replies are discarded.
    fn call(self: *Conn, msg_in: dbus.Message) !dbus.Message {
        var msg = msg_in;
        msg.serial = self.serial;
        self.serial += 1;
        const bytes = try dbus.marshal(self.allocator, msg);
        defer self.allocator.free(bytes);
        try self.writeAll(bytes);

        const deadline = self.deadline_ms;
        while (true) {
            while (dbus.unmarshal(self.rbuf.items) catch return error.Proto) |got| {
                const m = got.msg;
                const matched = m.reply_serial != null and m.reply_serial.? == msg.serial;
                if (matched and m.mtype == .error_reply) {
                    try self.rbuf.replaceRange(self.allocator, 0, got.consumed, &.{});
                    return error.DbusError;
                }
                if (matched) {
                    const body = try self.allocator.dupe(u8, m.body);
                    var copy = m;
                    copy.body = body;
                    try self.rbuf.replaceRange(self.allocator, 0, got.consumed, &.{});
                    return copy;
                }
                try self.rbuf.replaceRange(self.allocator, 0, got.consumed, &.{});
            }
            try self.waitFd(c.POLLIN, deadline);
            var tmp: [16384]u8 = undefined;
            const n = c.read(self.fd, &tmp, tmp.len);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n < 0 and std.posix.errno(n) == .AGAIN) continue;
            if (n <= 0) return error.Closed;
            try self.rbuf.appendSlice(self.allocator, tmp[0..@intCast(n)]);
        }
    }
};

// ── recursive tree serializer ───────────────────────────────────

const Ref = struct { dest: []u8, path: []u8 };

const Walker = struct {
    allocator: std.mem.Allocator,
    conn: *Conn,
    out: *std.ArrayList(u8),
    count: usize,

    fn node(self: *Walker, dest: []const u8, path: []const u8, depth: usize) !void {
        self.count += 1;
        const a = self.allocator;
        const w = self.out;

        const role_num = self.role(dest, path) catch 0;
        const name = self.stringProp(dest, path, ATSPI_ACCESSIBLE, "Name") catch "";
        defer a.free(name);
        const accessible_id = self.stringProp(dest, path, ATSPI_ACCESSIBLE, "AccessibleId") catch "";
        defer a.free(accessible_id);
        const desc = self.stringProp(dest, path, ATSPI_ACCESSIBLE, "Description") catch "";
        defer a.free(desc);
        const st = self.states(dest, path) catch [2]u32{ 0, 0 };
        const ext = self.extents(dest, path);

        try w.appendSlice(a, "{\"id\":\"");
        try makeId(w, a, dest, path);
        try w.appendSlice(a, "\",\"role\":");
        try printInt(w, a, role_num);
        try w.appendSlice(a, ",\"name\":");
        try printJsonString(w, a, name);
        try appendAccessibleId(w, a, accessible_id);
        if (desc.len > 0) {
            try w.appendSlice(a, ",\"desc\":");
            try printJsonString(w, a, desc);
        }
        try w.appendSlice(a, ",\"states\":[");
        try printInt(w, a, st[0]);
        try w.appendSlice(a, ",");
        try printInt(w, a, st[1]);
        try w.appendSlice(a, "]");
        if (ext) |e| {
            try w.appendSlice(a, ",\"rect\":[");
            try printIntI(w, a, e[0]);
            try w.appendSlice(a, ",");
            try printIntI(w, a, e[1]);
            try w.appendSlice(a, ",");
            try printIntI(w, a, e[2]);
            try w.appendSlice(a, ",");
            try printIntI(w, a, e[3]);
            try w.appendSlice(a, "]");
        }
        // Value.CurrentValue for nodes that expose the Value interface
        // (sliders, spinners, progress, scrollbars) — lets the
        // assistant read a control's setting and confirm set_value.
        if (self.currentValue(dest, path)) |v| {
            var vbuf: [32]u8 = undefined;
            const vs = std.fmt.bufPrint(&vbuf, "{d}", .{v}) catch "";
            try w.appendSlice(a, ",\"value\":");
            try w.appendSlice(a, vs);
        }

        var kids = self.children(dest, path) catch std.ArrayList(Ref).empty;
        defer {
            for (kids.items) |k| {
                a.free(k.dest);
                a.free(k.path);
            }
            kids.deinit(a);
        }
        if (kids.items.len > 0 and depth < MAX_DEPTH and self.count < MAX_NODES) {
            try w.appendSlice(a, ",\"children\":[");
            var first = true;
            for (kids.items) |k| {
                if (self.count >= MAX_NODES) break;
                if (!first) try w.appendSlice(a, ",");
                first = false;
                try self.node(k.dest, k.path, depth + 1);
            }
            try w.appendSlice(a, "]");
        }
        try w.append(a, '}');
    }

    fn children(self: *Walker, dest: []const u8, path: []const u8) !std.ArrayList(Ref) {
        const r = try self.conn.call(.{
            .mtype = .method_call,
            .path = path,
            .interface = ATSPI_ACCESSIBLE,
            .member = "GetChildren",
            .destination = dest,
        });
        defer self.allocator.free(r.body);
        var rd = dbus.Reader.init(r.body);
        var sub = try rd.array(8); // a(so)
        var list: std.ArrayList(Ref) = .empty;
        errdefer {
            for (list.items) |k| {
                self.allocator.free(k.dest);
                self.allocator.free(k.path);
            }
            list.deinit(self.allocator);
        }
        while (!sub.atEnd()) {
            try sub.structStart();
            const d = try sub.string();
            const p = try sub.string();
            try list.append(self.allocator, .{
                .dest = try self.allocator.dupe(u8, d),
                .path = try self.allocator.dupe(u8, p),
            });
        }
        return list;
    }

    fn role(self: *Walker, dest: []const u8, path: []const u8) !u32 {
        const r = try self.conn.call(.{
            .mtype = .method_call,
            .path = path,
            .interface = ATSPI_ACCESSIBLE,
            .member = "GetRole",
            .destination = dest,
        });
        defer self.allocator.free(r.body);
        var rd = dbus.Reader.init(r.body);
        return rd.u32v();
    }

    /// GetState returns au (two u32 bitfields).
    fn states(self: *Walker, dest: []const u8, path: []const u8) ![2]u32 {
        const r = try self.conn.call(.{
            .mtype = .method_call,
            .path = path,
            .interface = ATSPI_ACCESSIBLE,
            .member = "GetState",
            .destination = dest,
        });
        defer self.allocator.free(r.body);
        var rd = dbus.Reader.init(r.body);
        var sub = try rd.array(4);
        var lo: u32 = 0;
        var hi: u32 = 0;
        if (!sub.atEnd()) lo = try sub.u32v();
        if (!sub.atEnd()) hi = try sub.u32v();
        return .{ lo, hi };
    }

    /// Component.GetExtents(coord_type=0 screen) → (iiii). Null when
    /// the node has no Component interface (call errors).
    fn extents(self: *Walker, dest: []const u8, path: []const u8) ?[4]i32 {
        var bw = dbus.Writer.init(self.allocator);
        defer bw.deinit();
        bw.putU32(0) catch return null; // coordinate type: screen
        const r = self.conn.call(.{
            .mtype = .method_call,
            .path = path,
            .interface = "org.a11y.atspi.Component",
            .member = "GetExtents",
            .destination = dest,
            .signature = "u",
            .body = bw.buf.items,
        }) catch return null;
        defer self.allocator.free(r.body);
        var rd = dbus.Reader.init(r.body);
        rd.structStart() catch return null;
        const x = rd.i32v() catch return null;
        const y = rd.i32v() catch return null;
        const wd = rd.i32v() catch return null;
        const ht = rd.i32v() catch return null;
        return .{ x, y, wd, ht };
    }

    /// org.a11y.atspi.Value.CurrentValue (a double), or null when the
    /// node has no Value interface (Properties.Get errors / wrong type).
    fn currentValue(self: *Walker, dest: []const u8, path: []const u8) ?f64 {
        var bw = dbus.Writer.init(self.allocator);
        defer bw.deinit();
        bw.putString("org.a11y.atspi.Value") catch return null;
        bw.putString("CurrentValue") catch return null;
        const r = self.conn.call(.{
            .mtype = .method_call,
            .path = path,
            .interface = "org.freedesktop.DBus.Properties",
            .member = "Get",
            .destination = dest,
            .signature = "ss",
            .body = bw.buf.items,
        }) catch return null;
        defer self.allocator.free(r.body);
        var rd = dbus.Reader.init(r.body);
        const vsig = rd.sig() catch return null;
        if (vsig.len != 1 or vsig[0] != 'd') return null;
        return rd.f64v() catch null;
    }

    fn stringProp(self: *Walker, dest: []const u8, path: []const u8, iface: []const u8, prop: []const u8) ![]u8 {
        var bw = dbus.Writer.init(self.allocator);
        defer bw.deinit();
        try bw.putString(iface);
        try bw.putString(prop);
        const r = try self.conn.call(.{
            .mtype = .method_call,
            .path = path,
            .interface = "org.freedesktop.DBus.Properties",
            .member = "Get",
            .destination = dest,
            .signature = "ss",
            .body = bw.buf.items,
        });
        defer self.allocator.free(r.body);
        var rd = dbus.Reader.init(r.body);
        const vsig = try rd.sig();
        if (vsig.len == 0 or vsig[0] != 's') return self.allocator.dupe(u8, "");
        const s = try rd.string();
        return self.allocator.dupe(u8, s);
    }
};

fn printInt(w: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    try w.appendSlice(a, s);
}
fn printIntI(w: *std.ArrayList(u8), a: std.mem.Allocator, v: i32) !void {
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
    try w.appendSlice(a, s);
}

fn appendAccessibleId(w: *std.ArrayList(u8), a: std.mem.Allocator, id: []const u8) !void {
    if (id.len == 0) return;
    try w.appendSlice(a, ",\"accessible_id\":");
    try printJsonString(w, a, id);
}

fn printJsonString(w: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try w.append(a, '"');
    for (s) |ch| switch (ch) {
        '"' => try w.appendSlice(a, "\\\""),
        '\\' => try w.appendSlice(a, "\\\\"),
        '\n' => try w.appendSlice(a, "\\n"),
        '\r' => try w.appendSlice(a, "\\r"),
        '\t' => try w.appendSlice(a, "\\t"),
        0...8, 11, 12, 14...31 => {
            var buf: [8]u8 = undefined;
            const e = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch continue;
            try w.appendSlice(a, e);
        },
        else => try w.append(a, ch),
    };
    try w.append(a, '"');
}

test "json string escaping is well-formed" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try printJsonString(&out, a, "a\"b\\c\n");
    try std.testing.expectEqualStrings("\"a\\\"b\\\\c\\n\"", out.items);
}

test "AT-SPI AccessibleId is not promoted to a desktop app id" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try appendAccessibleId(&out, a, "QApplication");
    try std.testing.expectEqualStrings(",\"accessible_id\":\"QApplication\"", out.items);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"app_id\"") == null);
}

test "parseUnixPath extracts path and abstract forms" {
    try std.testing.expectEqualStrings("/run/x", parseUnixPath("unix:path=/run/x,guid=ab").?);
    const abs = parseUnixPath("unix:abstract=/tmp/dbus-XYZ,guid=1").?;
    try std.testing.expect(abs[0] == '@');
    try std.testing.expectEqualStrings("/tmp/dbus-XYZ", abs[1..]);
    try std.testing.expect(parseUnixPath("tcp:host=x") == null);
}
