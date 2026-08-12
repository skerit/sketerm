//! AT-SPI2 projection of a web face's mirrored AX tree (read-only).
//!
//! WHY THIS SEAM: GTK4's own AT-SPI backend is internal — a
//! `GtkAccessible` cannot answer a screen reader's child walk with a
//! foreign (bus-name, object-path) reference, so a page-scale tree
//! cannot be nested under the pane's widget accessible, and rebuilding
//! thousands of page nodes as GTK accessibles is exactly what the
//! design doc rules out. What CAN carry a page tree is the a11y bus
//! itself: this module opens its OWN connection to the session's
//! accessibility bus, serves the `org.a11y.atspi` interfaces for the
//! page nodes directly (pure-Zig D-Bus over `mux/dbus.zig`, the same
//! codec the daemon's a11y snapshot client uses — no GDBus, no
//! libatspi), and registers the tree as its own accessible APPLICATION
//! via `org.a11y.atspi.Socket.Embed` on the registry. That is
//! Chromium's own shape on Linux: the page appears as an application
//! of its own on the accessibility desktop, next to the toolkit's
//! window tree rather than inside it.
//!
//! GLib-free by construction so the smoke rig can drive it headless
//! against a private bus (`mux/a11yhub.zig`); the GUI owner watches
//! `fd` with `g_unix_fd_add` and calls `step` on readability.
//!
//! SERVED: Accessible (role/name/state/children/parent/attributes),
//! Component (extents from the offset-container chain, plus
//! `setOrigin` for screen coordinates), Application on the root,
//! Properties, Peer.Ping, Cache.GetItems, Action (press/click, routed
//! back out through `on_action` — see below), Text (content, caret
//! offset and selection) on text-bearing nodes, and the
//! `org.a11y.atspi.Event.Object` signals that tell a reader what
//! changed instead of making it re-walk.
//!
//! EVENTS ARE DIFFED, NOT REPLAYED. `publish` compares the tree
//! against a shadow of what was last put on the bus and emits only
//! real changes. Two properties are load-bearing:
//!   - The FIRST publish after connecting primes the shadow SILENTLY.
//!     A reader that just embedded learns the tree by walking it (or
//!     via Cache.GetItems); replaying it as thousands of
//!     children-changed signals would be a burst of pure noise.
//!   - A change larger than `resync_threshold` nodes (a navigation,
//!     say) collapses to ONE children-changed on the root and a silent
//!     re-prime, because a reader re-walks on that signal anyway and
//!     per-node signals for a whole new document is the same storm.
//!
//! ACTION ROUTES OUT, IT DOES NOT ACT. This module cannot reach the
//! engine and must not learn how: `DoAction` resolves the node to a
//! point through the same offset-container chain `GetExtents` uses and
//! hands it to the owner's `on_action` hook, which turns it into a
//! real trusted pointer event. That keeps the projection GLib-free and
//! engine-free (the smoke rig substitutes its own hook), and it is why
//! a screen-reader "press" is indistinguishable from a human click
//! rather than a synthetic DOM event.

const std = @import("std");
const c = @import("../c.zig").c;
const dbus = @import("../mux/dbus.zig");
const axtree = @import("../web/axtree.zig");
const proto = @import("../web/protocol.zig");

const ATSPI_ACCESSIBLE = "org.a11y.atspi.Accessible";
const ATSPI_COMPONENT = "org.a11y.atspi.Component";
const ATSPI_APPLICATION = "org.a11y.atspi.Application";
const ATSPI_ACTION = "org.a11y.atspi.Action";
const ATSPI_TEXT = "org.a11y.atspi.Text";
/// Object-event signals all ride one interface; the member is the
/// event class and the `detail` string its sub-type (the
/// "object:state-changed:focused" a reader knows is member
/// `StateChanged` + detail `focused`).
const ATSPI_EVENT_OBJECT = "org.a11y.atspi.Event.Object";
const PATH_PREFIX = "/org/a11y/atspi/accessible/";
const ROOT_PATH = "/org/a11y/atspi/accessible/root";
const CACHE_PATH = "/org/a11y/atspi/cache";
const NULL_PATH = "/org/a11y/atspi/null";
const REGISTRY_DEST = "org.a11y.atspi.Registry";

/// Total wall-clock budget for connect+auth+Embed.
const CONNECT_BUDGET_MS: i64 = 10_000;

pub fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

/// What a projected `DoAction` asks its owner to perform. Deliberately
/// a POINT rather than a node id: the owner talks to an engine that
/// keeps no accessibility tree of its own, so the mirror is the only
/// place a node can be resolved to somewhere on screen.
pub const ActionReq = struct {
    node_id: u32,
    /// Centre of the node, in the same view-local CSS pixels the wire
    /// carries (NOT screen coordinates — the origin offset is a
    /// presentation detail of `GetExtents`).
    x: i32,
    y: i32,
};

/// Returns whether the action was dispatched. False becomes a plain
/// `false` to the reader, never an error reply.
pub const ActionFn = *const fn (ctx: ?*anyopaque, req: ActionReq) bool;

/// Beyond this many added+removed nodes in one publish, per-node
/// signals are replaced by a single children-changed on the root.
const resync_threshold: usize = 64;

pub const Proj = struct {
    gpa: std.mem.Allocator,
    tree: *axtree.Tree,
    /// What the accessibility desktop lists this tree as ("sketerm web:
    /// <title>" in the GUI). Owned.
    app_name: []u8,
    fd: c_int = -1,
    serial: u32 = 1,
    rbuf: std.ArrayList(u8) = .empty,
    /// Our unique name on the a11y bus (":1.23"), from Hello.
    unique: [64]u8 = @splat(0),
    unique_len: usize = 0,
    /// The desktop parent Embed handed back — our root's Parent ref.
    parent_name: [128]u8 = @splat(0),
    parent_name_len: usize = 0,
    parent_path: [128]u8 = @splat(0),
    parent_path_len: usize = 0,
    embedded: bool = false,
    /// Screen origin of the view, for COORD_TYPE_SCREEN extents. The
    /// GUI updates it on allocation; 0,0 degrades to window coords.
    origin_x: i32 = 0,
    origin_y: i32 = 0,
    /// Scratch for `childIds`' one-element root list.
    root_child: [1]u32 = .{0},
    /// Where a projected `DoAction` goes. Null = the Action interface
    /// is still ADVERTISED (the node really is actionable) but every
    /// press answers false, which is the honest answer for a
    /// projection whose owner has not wired a route.
    on_action: ?ActionFn = null,
    action_ctx: ?*anyopaque = null,
    /// What was last published, so `publish` emits changes only.
    shadow: std.AutoHashMapUnmanaged(u32, Shadow) = .empty,
    primed: bool = false,
    pub_focus: u32 = 0,
    pub_caret_id: u32 = 0,
    pub_caret_off: i32 = 0,
    pub_sel_id: u32 = 0,
    pub_sel: [2]i32 = .{ 0, 0 },

    /// One node as last published. `children` is an owned copy: a
    /// precise children-changed needs the OLD list, and a hash could
    /// only say "something moved".
    const Shadow = struct {
        parent: u32,
        state: u64,
        name_hash: u64,
        children: []u32,
    };

    pub fn init(gpa: std.mem.Allocator, tree: *axtree.Tree, app_name: []const u8) !Proj {
        return .{ .gpa = gpa, .tree = tree, .app_name = try gpa.dupe(u8, app_name) };
    }

    pub fn deinit(self: *Proj) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.rbuf.deinit(self.gpa);
        self.gpa.free(self.app_name);
        self.clearShadow();
        self.shadow.deinit(self.gpa);
    }

    pub fn setOrigin(self: *Proj, x: i32, y: i32) void {
        self.origin_x = x;
        self.origin_y = y;
    }

    /// Route screen-reader presses. Set it before `publish`; the hook
    /// is called from `step`/`serveSlice`, i.e. on the owner's thread.
    pub fn setActionHook(self: *Proj, ctx: ?*anyopaque, f: ActionFn) void {
        self.action_ctx = ctx;
        self.on_action = f;
    }

    fn clearShadow(self: *Proj) void {
        var it = self.shadow.valueIterator();
        while (it.next()) |s| self.gpa.free(s.children);
        self.shadow.clearRetainingCapacity();
    }

    pub fn uniqueName(self: *const Proj) []const u8 {
        return self.unique[0..self.unique_len];
    }

    /// Rename the application (the GUI follows the page title).
    pub fn setAppName(self: *Proj, name: []const u8) void {
        const dup = self.gpa.dupe(u8, name) catch return;
        self.gpa.free(self.app_name);
        self.app_name = dup;
    }

    // ── bus bring-up ─────────────────────────────────────────────────

    /// Connect to the session's a11y bus and embed the tree.
    /// Discovery: `AT_SPI_BUS_ADDRESS`, else `session_bus_path` (or
    /// `$DBUS_SESSION_BUS_ADDRESS`) -> `org.a11y.Bus.GetAddress`.
    pub fn connect(self: *Proj, session_bus_path: ?[]const u8) !void {
        var deadline = nowMs() + CONNECT_BUDGET_MS;
        var a11y_path_buf: [256]u8 = undefined;
        var a11y_path: []const u8 = "";

        if (c.getenv("AT_SPI_BUS_ADDRESS")) |env| {
            a11y_path = parseUnixPath(std.mem.sliceTo(env, 0), &a11y_path_buf) orelse
                return error.BadBusAddress;
        } else {
            var sess_buf: [256]u8 = undefined;
            const sess_path = if (session_bus_path) |p|
                p
            else blk: {
                const env = c.getenv("DBUS_SESSION_BUS_ADDRESS") orelse return error.NoSessionBus;
                break :blk parseUnixPath(std.mem.sliceTo(env, 0), &sess_buf) orelse
                    return error.BadBusAddress;
            };
            const sfd = try busConnect(sess_path);
            defer _ = c.close(sfd);
            var sess = Proj{
                .gpa = self.gpa,
                .tree = self.tree,
                .app_name = self.app_name,
                .fd = sfd,
            };
            defer sess.rbuf.deinit(self.gpa);
            try sess.authAndHello(deadline);
            const reply = try sess.callBlocking(.{
                .mtype = .method_call,
                .path = "/org/a11y/bus",
                .interface = "org.a11y.Bus",
                .member = "GetAddress",
                .destination = "org.a11y.Bus",
            }, deadline);
            defer self.gpa.free(reply.body);
            var rd = dbus.Reader.init(reply.body);
            const addr = try rd.string();
            a11y_path = parseUnixPath(addr, &a11y_path_buf) orelse return error.BadBusAddress;
        }

        self.fd = try busConnect(a11y_path);
        errdefer {
            _ = c.close(self.fd);
            self.fd = -1;
        }
        deadline = @max(deadline, nowMs() + 2000);
        try self.authAndHello(deadline);
        try self.embed(deadline);
    }

    /// SASL EXTERNAL + Hello, recording our unique name.
    fn authAndHello(self: *Proj, deadline: i64) !void {
        try self.writeAll(&.{0}, deadline);
        var line: [128]u8 = undefined;
        var n: usize = 0;
        const head = "AUTH EXTERNAL ";
        @memcpy(line[0..head.len], head);
        n = head.len;
        var idbuf: [32]u8 = undefined;
        const dec = try std.fmt.bufPrint(&idbuf, "{d}", .{c.getuid()});
        for (dec) |ch| {
            _ = std.fmt.bufPrint(line[n..], "{x:0>2}", .{ch}) catch return error.Auth;
            n += 2;
        }
        @memcpy(line[n..][0..2], "\r\n");
        n += 2;
        try self.writeAll(line[0..n], deadline);
        var buf: [256]u8 = undefined;
        try waitFd(self.fd, c.POLLIN, deadline);
        const got = c.read(self.fd, &buf, buf.len);
        if (got <= 0) return error.Auth;
        if (!std.mem.startsWith(u8, buf[0..@intCast(got)], "OK")) return error.AuthRejected;
        try self.writeAll("BEGIN\r\n", deadline);

        const reply = try self.callBlocking(.{
            .mtype = .method_call,
            .path = "/org/freedesktop/DBus",
            .interface = "org.freedesktop.DBus",
            .member = "Hello",
            .destination = "org.freedesktop.DBus",
        }, deadline);
        defer self.gpa.free(reply.body);
        var rd = dbus.Reader.init(reply.body);
        const name = try rd.string();
        if (name.len > self.unique.len) return error.Auth;
        @memcpy(self.unique[0..name.len], name);
        self.unique_len = name.len;
    }

    /// `org.a11y.atspi.Socket.Embed(our root ref)` on the registry;
    /// the reply names the desktop parent our root reports.
    fn embed(self: *Proj, deadline: i64) !void {
        var bw = dbus.Writer.init(self.gpa);
        defer bw.deinit();
        try bw.pad(8);
        try bw.putString(self.uniqueName());
        try bw.putString(ROOT_PATH);
        const reply = try self.callBlocking(.{
            .mtype = .method_call,
            .path = ROOT_PATH,
            .interface = "org.a11y.atspi.Socket",
            .member = "Embed",
            .destination = REGISTRY_DEST,
            .signature = "(so)",
            .body = bw.buf.items,
        }, deadline);
        defer self.gpa.free(reply.body);
        var rd = dbus.Reader.init(reply.body);
        try rd.structStart();
        const pname = try rd.string();
        const ppath = try rd.string();
        if (pname.len > self.parent_name.len or ppath.len > self.parent_path.len)
            return error.EmbedReply;
        @memcpy(self.parent_name[0..pname.len], pname);
        self.parent_name_len = pname.len;
        @memcpy(self.parent_path[0..ppath.len], ppath);
        self.parent_path_len = ppath.len;
        self.embedded = true;
    }

    // ── serving ──────────────────────────────────────────────────────

    /// Drain the socket, answer every complete method call. False =
    /// the connection died (owner should drop the projection).
    pub fn step(self: *Proj) bool {
        if (self.fd < 0) return false;
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = c.read(self.fd, &buf, buf.len);
            if (n > 0) {
                self.rbuf.appendSlice(self.gpa, buf[0..@intCast(n)]) catch return false;
                if (@as(usize, @intCast(n)) < buf.len) break;
                continue;
            }
            if (n == 0) return false;
            const e = std.posix.errno(n);
            if (e == .AGAIN) break;
            if (e == .INTR) continue;
            return false;
        }
        while (true) {
            const got = (dbus.unmarshal(self.rbuf.items) catch return false) orelse break;
            const keep = self.dispatch(got.msg);
            self.rbuf.replaceRange(self.gpa, 0, got.consumed, &.{}) catch return false;
            if (!keep) return false;
        }
        return true;
    }

    /// Poll for readability up to `timeout_ms`, then answer what
    /// arrived. False = the connection is gone. The smoke rig's serve
    /// loop; the GUI instead watches `fd` and calls `step` directly.
    pub fn serveSlice(self: *Proj, timeout_ms: i64) bool {
        if (self.fd < 0) return false;
        waitFd(self.fd, c.POLLIN, nowMs() + timeout_ms) catch |err| switch (err) {
            error.Timeout => return true,
            else => return false,
        };
        return self.step();
    }

    /// Send one call and pump incoming traffic until its reply, still
    /// ANSWERING method calls that arrive meanwhile — the registry
    /// introspects the plug during Embed, so a blocked reader would
    /// deadlock the handshake. Returned body is caller-owned.
    fn callBlocking(self: *Proj, msg_in: dbus.Message, deadline: i64) !dbus.Message {
        var msg = msg_in;
        msg.serial = self.serial;
        self.serial += 1;
        const bytes = try dbus.marshal(self.gpa, msg);
        defer self.gpa.free(bytes);
        try self.writeAll(bytes, deadline);

        while (true) {
            while (try dbus.unmarshal(self.rbuf.items)) |got| {
                const m = got.msg;
                if (m.reply_serial != null and m.reply_serial.? == msg.serial) {
                    if (m.mtype == .error_reply) {
                        self.rbuf.replaceRange(self.gpa, 0, got.consumed, &.{}) catch {};
                        return error.DbusError;
                    }
                    const body = try self.gpa.dupe(u8, m.body);
                    var copy = m;
                    copy.body = body;
                    self.rbuf.replaceRange(self.gpa, 0, got.consumed, &.{}) catch {};
                    return copy;
                }
                _ = self.dispatch(m);
                self.rbuf.replaceRange(self.gpa, 0, got.consumed, &.{}) catch return error.OutOfMemory;
            }
            try waitFd(self.fd, c.POLLIN, deadline);
            var tmp: [16384]u8 = undefined;
            const n = c.read(self.fd, &tmp, tmp.len);
            if (n > 0) {
                try self.rbuf.appendSlice(self.gpa, tmp[0..@intCast(n)]);
                continue;
            }
            if (n == 0) return error.Closed;
            const e = std.posix.errno(n);
            if (e == .INTR or e == .AGAIN) continue;
            return error.Closed;
        }
    }

    fn writeAll(self: *Proj, bytes: []const u8, deadline: i64) !void {
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
                try waitFd(self.fd, c.POLLOUT, deadline);
                continue;
            }
            return error.Write;
        }
    }

    // ── event emission ───────────────────────────────────────────────

    /// Emit the AT-SPI signals describing what changed since the last
    /// call. The owner calls this after applying any a11y frame; it is
    /// cheap when nothing moved and never blocks on a reader.
    pub fn publish(self: *Proj) void {
        if (self.fd < 0) return;
        self.publishE() catch {
            // A failure mid-diff leaves the shadow disagreeing with
            // what the bus was told. Drop it: the next publish then
            // re-primes silently rather than emitting invented deltas.
            self.clearShadow();
            self.primed = false;
        };
    }

    fn publishE(self: *Proj) !void {
        if (!self.primed) {
            try self.reprime();
            self.primed = true;
            self.syncFocusCaret();
            return;
        }
        var churn: usize = 0;
        var it = self.tree.nodes.keyIterator();
        while (it.next()) |k| {
            if (!self.shadow.contains(k.*)) churn += 1;
        }
        var sit = self.shadow.keyIterator();
        while (sit.next()) |k| {
            if (self.tree.get(k.*) == null) churn += 1;
        }
        if (churn > resync_threshold) {
            // A whole new document. One signal, then re-prime: a
            // reader re-walks on this and per-node signals would be
            // the same information at a thousand times the cost.
            try self.reprime();
            self.emitObj(ROOT_PATH, "ChildrenChanged", "add", 0, 0, .{ .node = self.tree.root_id });
            self.emitFocusCaret();
            return;
        }
        try self.emitStructural();
        self.emitFocusCaret();
    }

    /// Replace the shadow with the current tree, emitting nothing.
    fn reprime(self: *Proj) !void {
        self.clearShadow();
        var it = self.tree.nodes.iterator();
        while (it.next()) |e| {
            const n = e.value_ptr;
            try self.shadow.put(self.gpa, n.id, .{
                .parent = self.parentOf(n.id) orelse 0,
                .state = n.state,
                .name_hash = std.hash.Wyhash.hash(0, n.name),
                .children = try self.gpa.dupe(u32, n.children),
            });
        }
    }

    /// Per-node diff. Structure changes are driven from the PARENT's
    /// child-list diff only — a newly present node is already covered
    /// by its parent's "add", so emitting on the child too would
    /// double-report every insertion.
    fn emitStructural(self: *Proj) !void {
        var path_buf: [64]u8 = undefined;
        // Nodes that survived: diff their children, name and state.
        var it = self.tree.nodes.iterator();
        while (it.next()) |e| {
            const n = e.value_ptr;
            const sh = self.shadow.getPtr(n.id) orelse continue;
            const path = nodePath(&path_buf, n.id);
            for (sh.children) |old_cid| {
                if (indexOfId(n.children, old_cid) == null) {
                    const idx = indexOfId(sh.children, old_cid) orelse 0;
                    self.emitObj(path, "ChildrenChanged", "remove", @intCast(idx), 0, .{ .node = old_cid });
                }
            }
            for (n.children, 0..) |cid, i| {
                if (indexOfId(sh.children, cid) == null)
                    self.emitObj(path, "ChildrenChanged", "add", @intCast(i), 0, .{ .node = cid });
            }
            const nh = std.hash.Wyhash.hash(0, n.name);
            if (nh != sh.name_hash)
                self.emitObj(path, "PropertyChange", "accessible-name", 0, 0, .{ .str = n.name });
            if (n.state != sh.state) self.emitStateDiff(path, sh.state, n.state);

            if (sh.children.len != n.children.len or
                !std.mem.eql(u32, sh.children, n.children))
            {
                const dup = try self.gpa.dupe(u32, n.children);
                self.gpa.free(sh.children);
                sh.children = dup;
            }
            sh.name_hash = nh;
            sh.state = n.state;
            sh.parent = self.parentOf(n.id) orelse 0;
        }
        // Retire shadows whose node is gone (their parent's diff, or
        // its own disappearance, already told the reader).
        var dead: std.ArrayList(u32) = .empty;
        defer dead.deinit(self.gpa);
        var sit = self.shadow.iterator();
        while (sit.next()) |e| {
            if (self.tree.get(e.key_ptr.*) == null) try dead.append(self.gpa, e.key_ptr.*);
        }
        for (dead.items) |id| {
            if (self.shadow.fetchRemove(id)) |kv| self.gpa.free(kv.value.children);
        }
        // Nodes that appeared: record them (no signal of their own).
        var nit = self.tree.nodes.iterator();
        while (nit.next()) |e| {
            const n = e.value_ptr;
            if (self.shadow.contains(n.id)) continue;
            try self.shadow.put(self.gpa, n.id, .{
                .parent = self.parentOf(n.id) orelse 0,
                .state = n.state,
                .name_hash = std.hash.Wyhash.hash(0, n.name),
                .children = try self.gpa.dupe(u32, n.children),
            });
        }
    }

    /// The state bits worth a signal. Only states a reader ACTS on:
    /// the full set would be churn, and `focused` is handled by the
    /// focus path so it is deliberately absent here.
    const reported_states = [_]struct { bit: u64, name: []const u8 }{
        .{ .bit = proto.ax_checked, .name = "checked" },
        .{ .bit = proto.ax_expanded, .name = "expanded" },
        .{ .bit = proto.ax_selected, .name = "selected" },
        .{ .bit = proto.ax_disabled, .name = "enabled" }, // inverted below
        .{ .bit = proto.ax_busy, .name = "busy" },
        .{ .bit = proto.ax_required, .name = "required" },
        .{ .bit = proto.ax_invisible, .name = "showing" }, // inverted below
    };

    fn emitStateDiff(self: *Proj, path: []const u8, old: u64, new: u64) void {
        for (reported_states) |rs| {
            const was = old & rs.bit != 0;
            const now = new & rs.bit != 0;
            if (was == now) continue;
            // `enabled`/`showing` are the negation of the wire bit.
            const inverted = rs.bit == proto.ax_disabled or rs.bit == proto.ax_invisible;
            const on: i32 = if (inverted) @intFromBool(!now) else @intFromBool(now);
            self.emitObj(path, "StateChanged", rs.name, on, 0, .none);
        }
    }

    /// Record focus/caret as published without emitting (used by the
    /// silent prime).
    fn syncFocusCaret(self: *Proj) void {
        self.pub_focus = self.tree.focus_id;
        self.pub_caret_id = self.tree.caret_focus_id;
        self.pub_caret_off = self.tree.caretOffsetFor(self.pub_caret_id) orelse 0;
        self.pub_sel_id = self.tree.caret_focus_id;
        self.pub_sel = self.tree.selectionFor(self.pub_sel_id) orelse .{ 0, 0 };
    }

    fn emitFocusCaret(self: *Proj) void {
        var path_buf: [64]u8 = undefined;
        const focus = self.tree.focus_id;
        if (focus != self.pub_focus) {
            // Unfocus first: a reader that sees two objects claiming
            // focus in the wrong order announces the stale one.
            if (self.pub_focus != 0 and self.tree.get(self.pub_focus) != null)
                self.emitObj(nodePath(&path_buf, self.pub_focus), "StateChanged", "focused", 0, 0, .none);
            if (focus != 0 and self.tree.get(focus) != null) {
                const p = nodePath(&path_buf, focus);
                self.emitObj(p, "StateChanged", "focused", 1, 0, .none);
            }
            self.pub_focus = focus;
        }

        const cid = self.tree.caret_focus_id;
        const coff = self.tree.caretOffsetFor(cid) orelse 0;
        if (cid != self.pub_caret_id or coff != self.pub_caret_off) {
            if (cid != 0) {
                if (self.tree.get(cid) != null) {
                    // Already a CHARACTER offset: the mirror converts
                    // the wire's UTF-16 units, where the text lives.
                    self.emitObj(nodePath(&path_buf, cid), "TextCaretMoved", "", coff, 0, .none);
                }
            }
            self.pub_caret_id = cid;
            self.pub_caret_off = coff;
        }

        const sel = self.tree.selectionFor(cid) orelse [2]i32{ 0, 0 };
        if (cid != self.pub_sel_id or sel[0] != self.pub_sel[0] or sel[1] != self.pub_sel[1]) {
            if (cid != 0 and self.tree.get(cid) != null)
                self.emitObj(nodePath(&path_buf, cid), "TextSelectionChanged", "", 0, 0, .none);
            self.pub_sel_id = cid;
            self.pub_sel = sel;
        }
    }

    /// `any_data` of an object event.
    const Any = union(enum) {
        none,
        int: i32,
        str: []const u8,
        node: u32,
    };

    fn emitObj(
        self: *Proj,
        path: []const u8,
        member: []const u8,
        detail: []const u8,
        d1: i32,
        d2: i32,
        any: Any,
    ) void {
        self.emitObjE(path, member, detail, d1, d2, any) catch {};
    }

    fn emitObjE(
        self: *Proj,
        path: []const u8,
        member: []const u8,
        detail: []const u8,
        d1: i32,
        d2: i32,
        any: Any,
    ) !void {
        var bw = dbus.Writer.init(self.gpa);
        defer bw.deinit();
        try bw.putString(detail);
        try bw.putI32(d1);
        try bw.putI32(d2);
        switch (any) {
            .none => {
                try bw.putSig("i");
                try bw.putI32(0);
            },
            .int => |v| {
                try bw.putSig("i");
                try bw.putI32(v);
            },
            .str => |s| try bw.putVariantString(s),
            .node => |id| {
                try bw.putSig("(so)");
                try self.putNodeRef(&bw, id);
            },
        }
        // properties a{sv}: AT-SPI carries none on these events.
        const tok = try bw.beginArray(8);
        bw.endArray(tok);

        const msg: dbus.Message = .{
            .mtype = .signal,
            .serial = self.serial,
            .path = path,
            .interface = ATSPI_EVENT_OBJECT,
            .member = member,
            .signature = "siiva{sv}",
            .body = bw.buf.items,
        };
        self.serial += 1;
        const bytes = try dbus.marshal(self.gpa, msg);
        defer self.gpa.free(bytes);
        try self.writeAll(bytes, nowMs() + 2000);
    }

    // ── request handling ─────────────────────────────────────────────

    const Target = union(enum) { root, node: u32, cache, unknown };

    fn targetOf(path: []const u8) Target {
        if (std.mem.eql(u8, path, ROOT_PATH)) return .root;
        if (std.mem.eql(u8, path, CACHE_PATH)) return .cache;
        if (std.mem.startsWith(u8, path, PATH_PREFIX)) {
            const id = std.fmt.parseInt(u32, path[PATH_PREFIX.len..], 10) catch return .unknown;
            return .{ .node = id };
        }
        return .unknown;
    }

    /// Answer one message. False only on a fatal transport error.
    fn dispatch(self: *Proj, m: dbus.Message) bool {
        if (m.mtype != .method_call) return true;
        const iface = m.interface orelse "";
        const member = m.member orelse "";
        const path = m.path orelse "";
        const no_reply = m.flags & 1 != 0;

        var bw = dbus.Writer.init(self.gpa);
        defer bw.deinit();
        var sig: []const u8 = "";
        var ok = true;

        if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Peer") and
            std.mem.eql(u8, member, "Ping"))
        {
            // empty reply
        } else if (std.mem.eql(u8, path, CACHE_PATH)) {
            if (std.mem.eql(u8, member, "GetItems")) {
                sig = "a((so)(so)(so)iiassusau)";
                self.putCacheItems(&bw) catch {
                    ok = false;
                };
            } else ok = false;
        } else switch (targetOf(path)) {
            .root => ok = self.answerObject(&bw, &sig, null, iface, member, m.body),
            .node => |id| blk: {
                const n = self.tree.get(id) orelse {
                    ok = false;
                    break :blk;
                };
                ok = self.answerObject(&bw, &sig, n, iface, member, m.body);
            },
            else => ok = false,
        }

        if (no_reply) return true;
        var reply: dbus.Message = .{
            .mtype = if (ok) .method_return else .error_reply,
            .serial = self.serial,
            .reply_serial = m.serial,
            .destination = m.sender,
        };
        self.serial += 1;
        if (ok) {
            if (sig.len != 0) reply.signature = sig;
            reply.body = bw.buf.items;
        } else {
            reply.error_name = "org.freedesktop.DBus.Error.UnknownMethod";
        }
        const bytes = dbus.marshal(self.gpa, reply) catch return false;
        defer self.gpa.free(bytes);
        self.writeAll(bytes, nowMs() + 2000) catch return false;
        return true;
    }

    /// Accessible/Component/Application/Properties on the root
    /// (`node == null`) or a page node. Returns false for anything
    /// unserved (becomes an UnknownMethod error reply).
    fn answerObject(
        self: *Proj,
        bw: *dbus.Writer,
        sig: *[]const u8,
        node: ?*const axtree.Node,
        iface: []const u8,
        member: []const u8,
        body: []const u8,
    ) bool {
        return self.answerObjectE(bw, sig, node, iface, member, body) catch false;
    }

    fn answerObjectE(
        self: *Proj,
        bw: *dbus.Writer,
        sig: *[]const u8,
        node: ?*const axtree.Node,
        iface: []const u8,
        member: []const u8,
        body: []const u8,
    ) !bool {
        if (std.mem.eql(u8, iface, "org.freedesktop.DBus.Properties")) {
            var rd = dbus.Reader.init(body);
            if (std.mem.eql(u8, member, "Get")) {
                const piface = try rd.string();
                const pname = try rd.string();
                sig.* = "v";
                return self.putProperty(bw, node, piface, pname);
            }
            if (std.mem.eql(u8, member, "GetAll")) {
                const piface = try rd.string();
                sig.* = "a{sv}";
                try self.putAllProperties(bw, node, piface);
                return true;
            }
            return false;
        }

        if (std.mem.eql(u8, iface, ATSPI_ACCESSIBLE)) {
            if (std.mem.eql(u8, member, "GetRole")) {
                sig.* = "u";
                try bw.putU32(if (node) |n| roleNumber(n) else 75); // APPLICATION
                return true;
            }
            if (std.mem.eql(u8, member, "GetRoleName")) {
                sig.* = "s";
                try bw.putString(if (node) |n| n.role else "application");
                return true;
            }
            if (std.mem.eql(u8, member, "GetLocalizedRoleName")) {
                sig.* = "s";
                try bw.putString(if (node) |n| n.role else "application");
                return true;
            }
            if (std.mem.eql(u8, member, "GetState")) {
                sig.* = "au";
                const words = self.stateWords(node);
                const tok = try bw.beginArray(4);
                try bw.putU32(words[0]);
                try bw.putU32(words[1]);
                bw.endArray(tok);
                return true;
            }
            if (std.mem.eql(u8, member, "GetChildAtIndex")) {
                var rd = dbus.Reader.init(body);
                const idx = try rd.i32v();
                sig.* = "(so)";
                const kids = self.childIds(node);
                if (idx < 0 or @as(usize, @intCast(idx)) >= kids.len) {
                    try self.putNullRef(bw);
                    return true;
                }
                try self.putNodeRef(bw, kids[@intCast(idx)]);
                return true;
            }
            if (std.mem.eql(u8, member, "GetChildren")) {
                sig.* = "a(so)";
                const tok = try bw.beginArray(8);
                for (self.childIds(node)) |id| try self.putNodeRef(bw, id);
                bw.endArray(tok);
                return true;
            }
            if (std.mem.eql(u8, member, "GetIndexInParent")) {
                sig.* = "i";
                try bw.putI32(self.indexInParent(node));
                return true;
            }
            if (std.mem.eql(u8, member, "GetInterfaces")) {
                sig.* = "as";
                const tok = try bw.beginArray(4);
                try self.putInterfaceNames(bw, node);
                bw.endArray(tok);
                return true;
            }
            if (std.mem.eql(u8, member, "GetApplication")) {
                sig.* = "(so)";
                try self.putRef(bw, self.uniqueName(), ROOT_PATH);
                return true;
            }
            if (std.mem.eql(u8, member, "GetAttributes")) {
                sig.* = "a{ss}";
                const tok = try bw.beginArray(8);
                if (node) |n| {
                    for (n.attrs) |a| {
                        try bw.pad(8);
                        try bw.putString(a.key);
                        try bw.putString(a.value);
                    }
                }
                bw.endArray(tok);
                return true;
            }
            return false;
        }

        if (std.mem.eql(u8, iface, ATSPI_COMPONENT)) {
            if (std.mem.eql(u8, member, "GetExtents")) {
                var rd = dbus.Reader.init(body);
                const coord = try rd.u32v();
                sig.* = "(iiii)";
                const r = self.extents(node, coord);
                try bw.pad(8);
                try bw.putI32(r[0]);
                try bw.putI32(r[1]);
                try bw.putI32(r[2]);
                try bw.putI32(r[3]);
                return true;
            }
            if (std.mem.eql(u8, member, "GetPosition")) {
                var rd = dbus.Reader.init(body);
                const coord = try rd.u32v();
                sig.* = "ii";
                const r = self.extents(node, coord);
                try bw.putI32(r[0]);
                try bw.putI32(r[1]);
                return true;
            }
            if (std.mem.eql(u8, member, "GetSize")) {
                sig.* = "ii";
                const r = self.extents(node, 1);
                try bw.putI32(r[2]);
                try bw.putI32(r[3]);
                return true;
            }
            if (std.mem.eql(u8, member, "Contains")) {
                var rd = dbus.Reader.init(body);
                const px = try rd.i32v();
                const py = try rd.i32v();
                const coord = try rd.u32v();
                sig.* = "b";
                const r = self.extents(node, coord);
                const inside = px >= r[0] and py >= r[1] and px < r[0] + r[2] and py < r[1] + r[3];
                try bw.putBool(inside);
                return true;
            }
            if (std.mem.eql(u8, member, "GetAccessibleAtPoint")) {
                sig.* = "(so)";
                try self.putNullRef(bw); // hit testing: later, with focus
                return true;
            }
            if (std.mem.eql(u8, member, "GrabFocus")) {
                sig.* = "b";
                // Deliberately unimplemented: the engine's only
                // trusted route back is a POINTER event, and clicking
                // an element to focus it would also activate it. A
                // truthful false beats a press the user did not ask
                // for.
                try bw.putBool(false);
                return true;
            }
            return false;
        }

        if (std.mem.eql(u8, iface, ATSPI_ACTION)) {
            const n = node orelse return false;
            if (!isActionable(n)) return false;
            return self.answerAction(bw, sig, n, member, body);
        }

        if (std.mem.eql(u8, iface, ATSPI_TEXT)) {
            const n = node orelse return false;
            if (!n.hasText()) return false;
            return self.answerText(bw, sig, n, member, body);
        }

        return false;
    }

    /// `org.a11y.atspi.Action`. Exactly ONE action is offered — the
    /// default press — because the projection knows only that a node
    /// is actionable, never the engine's list of verbs for it.
    fn answerAction(
        self: *Proj,
        bw: *dbus.Writer,
        sig: *[]const u8,
        n: *const axtree.Node,
        member: []const u8,
        body: []const u8,
    ) !bool {
        if (std.mem.eql(u8, member, "GetActions")) {
            sig.* = "a(sss)";
            const tok = try bw.beginArray(8);
            try bw.pad(8);
            try bw.putString(action_name);
            try bw.putString(""); // description
            try bw.putString(""); // key binding
            bw.endArray(tok);
            return true;
        }
        if (std.mem.eql(u8, member, "GetName") or
            std.mem.eql(u8, member, "GetLocalizedName"))
        {
            var rd = dbus.Reader.init(body);
            const idx = try rd.i32v();
            sig.* = "s";
            try bw.putString(if (idx == 0) action_name else "");
            return true;
        }
        if (std.mem.eql(u8, member, "GetDescription") or
            std.mem.eql(u8, member, "GetKeyBinding"))
        {
            sig.* = "s";
            try bw.putString("");
            return true;
        }
        if (std.mem.eql(u8, member, "DoAction")) {
            var rd = dbus.Reader.init(body);
            const idx = try rd.i32v();
            sig.* = "b";
            try bw.putBool(idx == 0 and self.dispatchAction(n));
            return true;
        }
        return false;
    }

    /// Resolve the node to a point and hand it to the owner. The
    /// centre is used because a node's origin can sit exactly on a
    /// border pixel shared with a neighbour.
    fn dispatchAction(self: *Proj, n: *const axtree.Node) bool {
        const f = self.on_action orelse return false;
        const r = self.extents(n, 1); // view coords, never screen
        if (r[2] <= 0 or r[3] <= 0) return false; // nothing to aim at
        return f(self.action_ctx, .{
            .node_id = n.id,
            .x = r[0] + @divTrunc(r[2], 2),
            .y = r[1] + @divTrunc(r[3], 2),
        });
    }

    /// `org.a11y.atspi.Text`. Offsets on this interface are CHARACTER
    /// counts (what AT-SPI means and what a braille display steps by);
    /// the wire's byte offsets are converted at this boundary and
    /// never leak out.
    fn answerText(
        self: *Proj,
        bw: *dbus.Writer,
        sig: *[]const u8,
        n: *const axtree.Node,
        member: []const u8,
        body: []const u8,
    ) !bool {
        const txt = n.text();
        if (std.mem.eql(u8, member, "GetText")) {
            var rd = dbus.Reader.init(body);
            const cs = try rd.i32v();
            const ce = try rd.i32v();
            sig.* = "s";
            try bw.putString(sliceChars(txt, cs, ce));
            return true;
        }
        if (std.mem.eql(u8, member, "GetCaretOffset")) {
            sig.* = "i";
            try bw.putI32(self.caretChars(n));
            return true;
        }
        if (std.mem.eql(u8, member, "SetCaretOffset")) {
            sig.* = "b";
            try bw.putBool(false); // no trusted route to move a caret
            return true;
        }
        if (std.mem.eql(u8, member, "GetCharacterAtOffset")) {
            var rd = dbus.Reader.init(body);
            const ci = try rd.i32v();
            sig.* = "i";
            try bw.putI32(charAt(txt, ci));
            return true;
        }
        if (std.mem.eql(u8, member, "GetTextAtOffset") or
            std.mem.eql(u8, member, "GetTextBeforeOffset") or
            std.mem.eql(u8, member, "GetTextAfterOffset"))
        {
            var rd = dbus.Reader.init(body);
            const ci = try rd.i32v();
            const btype = try rd.u32v();
            const rel: Rel = if (std.mem.eql(u8, member, "GetTextBeforeOffset"))
                .before
            else if (std.mem.eql(u8, member, "GetTextAfterOffset"))
                .after
            else
                .at;
            const r = boundaryRange(txt, ci, btype, rel);
            sig.* = "sii";
            try bw.putString(sliceChars(txt, r[0], r[1]));
            try bw.putI32(r[0]);
            try bw.putI32(r[1]);
            return true;
        }
        if (std.mem.eql(u8, member, "GetNSelections")) {
            sig.* = "i";
            try bw.putI32(if (self.tree.selectionFor(n.id) != null) 1 else 0);
            return true;
        }
        if (std.mem.eql(u8, member, "GetSelection")) {
            var rd = dbus.Reader.init(body);
            const num = try rd.i32v();
            sig.* = "ii";
            const sel = self.tree.selectionFor(n.id);
            if (num != 0 or sel == null) {
                // AT-SPI's "no such selection": an empty range, not an
                // error — libatspi treats an error as a dead object.
                try bw.putI32(0);
                try bw.putI32(0);
                return true;
            }
            try bw.putI32(sel.?[0]);
            try bw.putI32(sel.?[1]);
            return true;
        }
        if (std.mem.eql(u8, member, "AddSelection") or
            std.mem.eql(u8, member, "RemoveSelection") or
            std.mem.eql(u8, member, "SetSelection"))
        {
            sig.* = "b";
            try bw.putBool(false); // no trusted route to move a selection
            return true;
        }
        if (std.mem.eql(u8, member, "GetAttributes") or
            std.mem.eql(u8, member, "GetAttributeRun"))
        {
            var rd = dbus.Reader.init(body);
            const ci = rd.i32v() catch 0;
            sig.* = "a{ss}ii";
            const tok = try bw.beginArray(8);
            bw.endArray(tok);
            // One run covering the whole string: no per-range text
            // attributes cross the wire, so claiming a shorter run
            // would make a reader re-query forever.
            _ = ci;
            try bw.putI32(0);
            try bw.putI32(utf8Len(txt));
            return true;
        }
        if (std.mem.eql(u8, member, "GetDefaultAttributes") or
            std.mem.eql(u8, member, "GetDefaultAttributeSet"))
        {
            sig.* = "a{ss}";
            const tok = try bw.beginArray(8);
            bw.endArray(tok);
            return true;
        }
        if (std.mem.eql(u8, member, "GetAttributeValue")) {
            sig.* = "s";
            try bw.putString("");
            return true;
        }
        if (std.mem.eql(u8, member, "GetCharacterExtents")) {
            var rd = dbus.Reader.init(body);
            const ci = try rd.i32v();
            const coord = try rd.u32v();
            sig.* = "iiii";
            const r = self.charExtents(n, ci, coord);
            try bw.putI32(r[0]);
            try bw.putI32(r[1]);
            try bw.putI32(r[2]);
            try bw.putI32(r[3]);
            return true;
        }
        if (std.mem.eql(u8, member, "GetRangeExtents")) {
            var rd = dbus.Reader.init(body);
            _ = try rd.i32v();
            _ = try rd.i32v();
            const coord = try rd.u32v();
            sig.* = "(iiii)";
            const r = self.extents(n, coord);
            try bw.pad(8);
            try bw.putI32(r[0]);
            try bw.putI32(r[1]);
            try bw.putI32(r[2]);
            try bw.putI32(r[3]);
            return true;
        }
        if (std.mem.eql(u8, member, "GetOffsetAtPoint")) {
            sig.* = "i";
            try bw.putI32(-1); // no per-character layout on this wire
            return true;
        }
        return false;
    }

    /// The caret as AT-SPI counts it. `caretOffsetFor` already returns
    /// characters, so this is only the "no caret here" default.
    fn caretChars(self: *Proj, n: *const axtree.Node) i32 {
        return self.tree.caretOffsetFor(n.id) orelse 0;
    }

    /// Per-character rect. The wire carries no glyph layout, so the
    /// node's own rect is divided evenly — enough for a reader to
    /// scroll to or magnify the caret, and honest about its precision
    /// (it degrades gracefully on a proportional font rather than
    /// claiming a position it cannot know).
    fn charExtents(self: *Proj, n: *const axtree.Node, ci: i32, coord: u32) [4]i32 {
        const r = self.extents(n, coord);
        const total = utf8Len(n.text());
        if (total <= 0 or ci < 0 or ci >= total) return .{ r[0], r[1], 0, r[3] };
        const cw = @divTrunc(r[2], total);
        return .{ r[0] + cw * ci, r[1], cw, r[3] };
    }

    fn putProperty(
        self: *Proj,
        bw: *dbus.Writer,
        node: ?*const axtree.Node,
        piface: []const u8,
        pname: []const u8,
    ) bool {
        return self.putPropertyE(bw, node, piface, pname) catch false;
    }

    fn putPropertyE(
        self: *Proj,
        bw: *dbus.Writer,
        node: ?*const axtree.Node,
        piface: []const u8,
        pname: []const u8,
    ) !bool {
        if (std.mem.eql(u8, piface, ATSPI_ACCESSIBLE) or piface.len == 0) {
            if (std.mem.eql(u8, pname, "Name")) {
                try bw.putVariantString(if (node) |n| n.name else self.app_name);
                return true;
            }
            if (std.mem.eql(u8, pname, "Description")) {
                try bw.putVariantString(if (node) |n| n.description else "");
                return true;
            }
            if (std.mem.eql(u8, pname, "ChildCount")) {
                try bw.putSig("i");
                try bw.putI32(@intCast(self.childIds(node).len));
                return true;
            }
            if (std.mem.eql(u8, pname, "Parent")) {
                try bw.putSig("(so)");
                if (node) |n| {
                    if (self.parentOf(n.id)) |pid| {
                        try self.putNodeRef(bw, pid);
                    } else if (n.id == self.tree.root_id) {
                        try self.putRef(bw, self.uniqueName(), ROOT_PATH);
                    } else {
                        try self.putNullRef(bw);
                    }
                } else if (self.embedded) {
                    try self.putRef(
                        bw,
                        self.parent_name[0..self.parent_name_len],
                        self.parent_path[0..self.parent_path_len],
                    );
                } else {
                    try self.putNullRef(bw);
                }
                return true;
            }
            if (std.mem.eql(u8, pname, "AccessibleId")) {
                try bw.putVariantString("");
                return true;
            }
        }
        // libatspi reads the caret through the PROPERTY, not through
        // GetCaretOffset — `atspi_text_get_caret_offset` is a
        // Properties.Get. Both are served; this is the one that runs.
        if (node != null and std.mem.eql(u8, piface, ATSPI_TEXT)) {
            const n = node.?;
            if (!n.hasText()) return false;
            if (std.mem.eql(u8, pname, "CharacterCount")) {
                try bw.putSig("i");
                try bw.putI32(utf8Len(n.text()));
                return true;
            }
            if (std.mem.eql(u8, pname, "CaretOffset")) {
                try bw.putSig("i");
                try bw.putI32(self.caretChars(n));
                return true;
            }
        }
        if (node != null and std.mem.eql(u8, piface, ATSPI_ACTION)) {
            if (std.mem.eql(u8, pname, "NActions")) {
                try bw.putSig("i");
                try bw.putI32(if (isActionable(node.?)) 1 else 0);
                return true;
            }
        }
        if (node == null and std.mem.eql(u8, piface, ATSPI_APPLICATION)) {
            if (std.mem.eql(u8, pname, "ToolkitName")) {
                try bw.putVariantString("sketerm");
                return true;
            }
            if (std.mem.eql(u8, pname, "Version") or std.mem.eql(u8, pname, "AtspiVersion")) {
                try bw.putVariantString("2.1");
                return true;
            }
        }
        return false;
    }

    fn putAllProperties(self: *Proj, bw: *dbus.Writer, node: ?*const axtree.Node, piface: []const u8) !void {
        const tok = try bw.beginArray(8);
        const names = [_][]const u8{ "Name", "Description", "ChildCount", "Parent" };
        for (names) |pn| {
            try bw.pad(8);
            try bw.putString(pn);
            // Always succeeds for these four; a would-be miss must
            // still write a value or the dict entry would be corrupt.
            if (!self.putProperty(bw, node, ATSPI_ACCESSIBLE, pn))
                try bw.putVariantString("");
        }
        if (node == null and std.mem.eql(u8, piface, ATSPI_APPLICATION)) {
            try bw.pad(8);
            try bw.putString("ToolkitName");
            _ = self.putProperty(bw, node, ATSPI_APPLICATION, "ToolkitName");
        }
        bw.endArray(tok);
    }

    /// `org.a11y.atspi.Cache.GetItems`: the whole tree in one reply,
    /// which is how libatspi-based readers prefetch.
    fn putCacheItems(self: *Proj, bw: *dbus.Writer) !void {
        const tok = try bw.beginArray(8);
        try self.putCacheItem(bw, null);
        var it = self.tree.nodes.valueIterator();
        while (it.next()) |n| try self.putCacheItem(bw, n);
        bw.endArray(tok);
    }

    fn putCacheItem(self: *Proj, bw: *dbus.Writer, node: ?*const axtree.Node) !void {
        try bw.pad(8);
        // (so) this object
        if (node) |n| try self.putNodeRef(bw, n.id) else try self.putRef(bw, self.uniqueName(), ROOT_PATH);
        // (so) application
        try self.putRef(bw, self.uniqueName(), ROOT_PATH);
        // (so) parent
        if (node) |n| {
            if (self.parentOf(n.id)) |pid|
                try self.putNodeRef(bw, pid)
            else if (n.id == self.tree.root_id)
                try self.putRef(bw, self.uniqueName(), ROOT_PATH)
            else
                try self.putNullRef(bw);
        } else if (self.embedded) {
            try self.putRef(bw, self.parent_name[0..self.parent_name_len], self.parent_path[0..self.parent_path_len]);
        } else try self.putNullRef(bw);
        try bw.putI32(self.indexInParent(node));
        try bw.putI32(@intCast(self.childIds(node).len));
        // as interfaces
        const itok = try bw.beginArray(4);
        try self.putInterfaceNames(bw, node);
        bw.endArray(itok);
        // s name, u role, s description
        try bw.putString(if (node) |n| n.name else self.app_name);
        try bw.putU32(if (node) |n| roleNumber(n) else 75);
        try bw.putString(if (node) |n| n.description else "");
        // au states
        const words = self.stateWords(node);
        const stok = try bw.beginArray(4);
        try bw.putU32(words[0]);
        try bw.putU32(words[1]);
        bw.endArray(stok);
    }

    /// The interface list for one object. Kept in ONE place because
    /// `GetInterfaces` and the Cache item must never disagree — a
    /// reader that prefetches the cache would then never ask an
    /// interface the walk says exists.
    fn putInterfaceNames(self: *Proj, bw: *dbus.Writer, node: ?*const axtree.Node) !void {
        _ = self;
        try bw.putString(ATSPI_ACCESSIBLE);
        try bw.putString(ATSPI_COMPONENT);
        const n = node orelse {
            try bw.putString(ATSPI_APPLICATION);
            return;
        };
        if (isActionable(n)) try bw.putString(ATSPI_ACTION);
        if (n.hasText()) try bw.putString(ATSPI_TEXT);
    }

    // ── tree queries ─────────────────────────────────────────────────

    fn childIds(self: *Proj, node: ?*const axtree.Node) []const u32 {
        if (node) |n| return n.children;
        if (self.tree.root_id != 0 and self.tree.get(self.tree.root_id) != null) {
            self.root_child[0] = self.tree.root_id;
            return self.root_child[0..1];
        }
        return &.{};
    }

    /// Parent NODE id (null for the tree root and unknown ids).
    fn parentOf(self: *Proj, id: u32) ?u32 {
        if (id == self.tree.root_id) return null;
        var it = self.tree.nodes.iterator();
        while (it.next()) |e| {
            for (e.value_ptr.children) |cid| {
                if (cid == id) return e.key_ptr.*;
            }
        }
        return null;
    }

    fn indexInParent(self: *Proj, node: ?*const axtree.Node) i32 {
        const n = node orelse return -1; // the desktop knows our index, we do not
        if (n.id == self.tree.root_id) return 0;
        const pid = self.parentOf(n.id) orelse return -1;
        const p = self.tree.get(pid) orelse return -1;
        for (p.children, 0..) |cid, i| {
            if (cid == n.id) return @intCast(i);
        }
        return -1;
    }

    /// Absolute rect: the wire's rects are relative to their offset
    /// container, so absolute = the chain's sum. coord 0 (screen) adds
    /// the view origin the GUI supplied; anything else is window/view
    /// coordinates.
    fn extents(self: *Proj, node: ?*const axtree.Node, coord: u32) [4]i32 {
        const n = node orelse return .{ self.origin_x, self.origin_y, 0, 0 };
        var x = n.x;
        var y = n.y;
        var cur = n.offset_container;
        var depth: u32 = 0;
        while (cur != 0 and depth < 64) : (depth += 1) {
            const p = self.tree.get(cur) orelse break;
            x += p.x;
            y += p.y;
            cur = p.offset_container;
        }
        if (coord == 0) {
            x += self.origin_x;
            y += self.origin_y;
        }
        return .{ x, y, n.w, n.h };
    }

    fn stateWords(self: *Proj, node: ?*const axtree.Node) [2]u32 {
        var bits: u64 = 0;
        const set = struct {
            fn f(b: *u64, at: u6) void {
                b.* |= @as(u64, 1) << at;
            }
        }.f;
        const n = node orelse {
            set(&bits, 8); // ENABLED
            set(&bits, 24); // SENSITIVE
            set(&bits, 25); // SHOWING
            set(&bits, 30); // VISIBLE
            return .{ @truncate(bits), @truncate(bits >> 32) };
        };
        const s = n.state;
        if (s & proto.ax_disabled == 0) {
            set(&bits, 8); // ENABLED
            set(&bits, 24); // SENSITIVE
        }
        if (s & (proto.ax_invisible | proto.ax_ignored) == 0) {
            set(&bits, 25); // SHOWING
            set(&bits, 30); // VISIBLE
        }
        if (s & proto.ax_focusable != 0) set(&bits, 11);
        if (s & proto.ax_focused != 0 or n.id == self.tree.focus_id) set(&bits, 12);
        if (s & proto.ax_checked != 0) set(&bits, 4);
        if (s & proto.ax_checked_mixed != 0) set(&bits, 32); // INDETERMINATE
        if (s & proto.ax_editable != 0) set(&bits, 7);
        if (s & proto.ax_multiline != 0) set(&bits, 17);
        if (s & proto.ax_required != 0) set(&bits, 33);
        if (s & proto.ax_readonly != 0) set(&bits, 43);
        if (s & proto.ax_expanded != 0) {
            set(&bits, 9); // EXPANDABLE
            set(&bits, 10); // EXPANDED
        }
        if (s & proto.ax_collapsed != 0) set(&bits, 9);
        if (s & proto.ax_selected != 0) {
            set(&bits, 22); // SELECTABLE
            set(&bits, 23); // SELECTED
        }
        if (s & proto.ax_busy != 0) set(&bits, 3);
        if (s & proto.ax_modal != 0) set(&bits, 16);
        if (s & proto.ax_visited != 0) set(&bits, 40);
        if (s & proto.ax_multiselectable != 0) set(&bits, 18);
        return .{ @truncate(bits), @truncate(bits >> 32) };
    }

    // ── marshalling helpers ──────────────────────────────────────────

    fn putRef(self: *Proj, bw: *dbus.Writer, name: []const u8, path: []const u8) !void {
        _ = self;
        try bw.pad(8);
        try bw.putString(name);
        try bw.putString(path);
    }

    fn putNullRef(self: *Proj, bw: *dbus.Writer) !void {
        try self.putRef(bw, self.uniqueName(), NULL_PATH);
    }

    fn putNodeRef(self: *Proj, bw: *dbus.Writer, id: u32) !void {
        var buf: [64]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}{d}", .{ PATH_PREFIX, id }) catch NULL_PATH;
        try self.putRef(bw, self.uniqueName(), path);
    }
};

/// The single action a projected node offers. "click" is the token
/// GTK's own AT-SPI backend uses for a default press, so a reader that
/// switches on the action NAME finds what it expects.
const action_name = "click";

/// Roles a user can operate even when the engine did not mark them
/// focusable (a `<div role=button tabindex=-1>` driven by script is
/// the common case). Focusable nodes qualify regardless of role.
const action_roles = [_][]const u8{
    "button",     "link",     "checkbox", "radio",    "switch",
    "menuitem",   "option",   "tab",      "treeitem", "combobox",
    "spinbutton", "slider",   "listitem", "cell",     "columnheader",
    "rowheader",  "menuitem",
};

fn isActionable(n: *const axtree.Node) bool {
    // A disabled control is not pressable, whatever its role.
    if (n.state & proto.ax_disabled != 0) return false;
    if (n.state & proto.ax_focusable != 0) return true;
    for (action_roles) |r| {
        if (std.mem.eql(u8, n.role, r)) return true;
    }
    return false;
}

fn nodePath(buf: *[64]u8, id: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{d}", .{ PATH_PREFIX, id }) catch NULL_PATH;
}

fn indexOfId(list: []const u32, id: u32) ?usize {
    for (list, 0..) |v, i| {
        if (v == id) return i;
    }
    return null;
}

// ── UTF-8: the wire counts BYTES, AT-SPI counts CHARACTERS ───────────
//
// Every offset crossing the bus goes through these. Beyond
// correctness on non-ASCII pages, they are what stops a byte offset
// splitting a codepoint: D-Bus rejects a string that is not valid
// UTF-8, so an unsnapped slice would drop the whole reply.

fn utf8Len(s: []const u8) i32 {
    var n: i32 = 0;
    var i: usize = 0;
    while (i < s.len) : (n += 1) i += utf8SeqLen(s[i]);
    return n;
}

fn utf8SeqLen(first: u8) usize {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

/// Byte offset of a character index, clamped to the string.
fn byteForChar(s: []const u8, ci: i32) usize {
    if (ci <= 0) return 0;
    var n: i32 = 0;
    var i: usize = 0;
    while (i < s.len and n < ci) : (n += 1) i += utf8SeqLen(s[i]);
    return @min(i, s.len);
}

/// `s[start..end)` in character offsets, always on codepoint
/// boundaries so the result is valid UTF-8 for the bus.
fn sliceChars(s: []const u8, start: i32, end: i32) []const u8 {
    const a = byteForChar(s, start);
    const b = byteForChar(s, end);
    if (b <= a) return "";
    return s[a..b];
}

/// The codepoint at a character index, or 0 past the end (AT-SPI's
/// "no character there").
fn charAt(s: []const u8, ci: i32) i32 {
    const a = byteForChar(s, ci);
    if (a >= s.len) return 0;
    const len = utf8SeqLen(s[a]);
    if (a + len > s.len) return 0;
    const cp = std.unicode.utf8Decode(s[a .. a + len]) catch return 0;
    return @intCast(cp);
}

const Rel = enum { before, at, after };

/// AT-SPI text boundary types.
const bt_char: u32 = 0;
const bt_word_start: u32 = 1;
const bt_word_end: u32 = 2;
const bt_sentence_start: u32 = 3;
const bt_sentence_end: u32 = 4;
const bt_line_start: u32 = 5;
const bt_line_end: u32 = 6;

/// The [start, end) CHARACTER range a `GetText*Offset` call asks for.
/// Sentence boundaries fall back to line boundaries: this wire carries
/// no sentence segmentation, and a wrong sentence split reads worse
/// than a line.
fn boundaryRange(s: []const u8, ci: i32, btype: u32, rel: Rel) [2]i32 {
    const total = utf8Len(s);
    const at = std.math.clamp(ci, 0, total);
    if (btype == bt_char) {
        return switch (rel) {
            .at => .{ at, @min(at + 1, total) },
            .before => .{ @max(at - 1, 0), at },
            .after => .{ @min(at + 1, total), @min(at + 2, total) },
        };
    }
    const word = btype == bt_word_start or btype == bt_word_end;
    var cur = spanAt(s, at, word);
    switch (rel) {
        .at => return cur,
        .before => {
            if (cur[0] <= 0) return .{ 0, 0 };
            return spanAt(s, cur[0] - 1, word);
        },
        .after => {
            if (cur[1] >= total) return .{ total, total };
            cur = spanAt(s, cur[1] + 1, word);
            return cur;
        },
    }
}

/// The word or line span containing character `at`.
fn spanAt(s: []const u8, at: i32, word: bool) [2]i32 {
    const total = utf8Len(s);
    if (total == 0) return .{ 0, 0 };
    const probe = @min(at, @max(total - 1, 0));
    var start = probe;
    while (start > 0 and !isBreak(charAt(s, start - 1), word)) start -= 1;
    var end = probe;
    while (end < total and !isBreak(charAt(s, end), word)) end += 1;
    // A line INCLUDES its trailing newline, matching every toolkit.
    if (!word and end < total) end += 1;
    return .{ start, end };
}

fn isBreak(cp: i32, word: bool) bool {
    if (cp == '\n') return true;
    if (!word) return false;
    return cp == ' ' or cp == '\t' or cp == '\r';
}

/// Wire role token -> AT-SPI role number (values from
/// atspi-constants.h, extracted by compile probe 2026-08-12).
fn roleNumber(n: *const axtree.Node) u32 {
    const Map = struct { t: []const u8, r: u32 };
    const map = [_]Map{
        .{ .t = "document", .r = 95 }, // DOCUMENT_WEB
        .{ .t = "generic", .r = 85 }, // SECTION
        .{ .t = "text", .r = 116 }, // STATIC
        .{ .t = "button", .r = 43 },
        .{ .t = "heading", .r = 83 },
        .{ .t = "link", .r = 88 },
        .{ .t = "paragraph", .r = 73 },
        .{ .t = "textbox", .r = 79 }, // ENTRY
        .{ .t = "searchbox", .r = 79 },
        .{ .t = "checkbox", .r = 7 },
        .{ .t = "radio", .r = 44 },
        .{ .t = "combobox", .r = 11 },
        .{ .t = "listbox", .r = 98 },
        .{ .t = "option", .r = 32 },
        .{ .t = "list", .r = 31 },
        .{ .t = "listitem", .r = 32 },
        .{ .t = "image", .r = 27 },
        .{ .t = "table", .r = 55 },
        .{ .t = "row", .r = 90 },
        .{ .t = "cell", .r = 56 },
        .{ .t = "columnheader", .r = 10 },
        .{ .t = "rowheader", .r = 47 },
        .{ .t = "dialog", .r = 16 },
        .{ .t = "alertdialog", .r = 16 },
        .{ .t = "alert", .r = 2 },
        .{ .t = "menu", .r = 33 },
        .{ .t = "menubar", .r = 34 },
        .{ .t = "menuitem", .r = 35 },
        .{ .t = "tab", .r = 37 },
        .{ .t = "tablist", .r = 38 },
        .{ .t = "tabpanel", .r = 85 },
        .{ .t = "toolbar", .r = 63 },
        .{ .t = "tooltip", .r = 64 },
        .{ .t = "tree", .r = 65 },
        .{ .t = "treeitem", .r = 91 },
        .{ .t = "progressbar", .r = 42 },
        .{ .t = "slider", .r = 51 },
        .{ .t = "spinbutton", .r = 52 },
        .{ .t = "switch", .r = 62 }, // TOGGLE_BUTTON
        .{ .t = "separator", .r = 50 },
        .{ .t = "caption", .r = 81 },
        .{ .t = "blockquote", .r = 105 },
        .{ .t = "form", .r = 87 },
        .{ .t = "article", .r = 109 },
        .{ .t = "main", .r = 110 }, // LANDMARK
        .{ .t = "navigation", .r = 110 },
        .{ .t = "banner", .r = 110 },
        .{ .t = "contentinfo", .r = 110 },
        .{ .t = "complementary", .r = 110 },
        .{ .t = "region", .r = 110 },
        .{ .t = "search", .r = 110 },
        .{ .t = "iframe", .r = 28 }, // INTERNAL_FRAME
        .{ .t = "marquee", .r = 112 },
        .{ .t = "label", .r = 29 },
    };
    // A protected entry reads as PASSWORD_TEXT whatever its token.
    if (n.state & proto.ax_protected != 0) return 40;
    for (map) |m| {
        if (std.mem.eql(u8, n.role, m.t)) return m.r;
    }
    return 85; // SECTION: unknown roles present as generic nodes
}

// ── plumbing ─────────────────────────────────────────────────────────

pub fn busConnect(path: []const u8) !c_int {
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
    return fd;
}

pub fn waitFd(fd: c_int, events: c_short, deadline: i64) !void {
    while (true) {
        const left: c_int = @intCast(@max(0, @min(deadline - nowMs(), std.math.maxInt(c_int))));
        if (left == 0) return error.Timeout;
        var pfd = c.struct_pollfd{ .fd = fd, .events = events, .revents = 0 };
        const rc = c.poll(&pfd, 1, left);
        if (rc > 0 and pfd.revents & events != 0) return;
        if (rc < 0 and std.posix.errno(rc) == .INTR) continue;
        if (rc == 0) return error.Timeout;
        return error.Closed;
    }
}

// ── tests ────────────────────────────────────────────────────────────

const t = std.testing;

test "character offsets survive multi-byte text" {
    // "héllo" is 6 BYTES but 5 CHARACTERS: every AT-SPI offset is the
    // second number, and mixing them up is what splits a codepoint.
    const s = "h\u{e9}llo";
    try t.expectEqual(@as(usize, 6), s.len);
    try t.expectEqual(@as(i32, 5), utf8Len(s));

    // Character 2 is the 'l' after the 2-byte 'é' -> byte 3.
    try t.expectEqual(@as(usize, 3), byteForChar(s, 2));
    // Past the end clamps to the string rather than running off it.
    try t.expectEqual(@as(usize, 6), byteForChar(s, 99));
    try t.expectEqual(@as(usize, 0), byteForChar(s, -4));
    try t.expectEqualStrings("h\u{e9}", sliceChars(s, 0, 2));
    try t.expectEqualStrings("llo", sliceChars(s, 2, 5));
    // Out-of-range slices clamp instead of trapping.
    try t.expectEqualStrings("", sliceChars(s, 9, 12));
    try t.expectEqualStrings("h\u{e9}llo", sliceChars(s, 0, 99));
    try t.expectEqual(@as(i32, 0xe9), charAt(s, 1));
    try t.expectEqual(@as(i32, 0), charAt(s, 99));
}

test "text boundaries: char, word and line" {
    const s = "one two\nthree";
    // char
    try t.expectEqual([2]i32{ 0, 1 }, boundaryRange(s, 0, bt_char, .at));
    try t.expectEqual([2]i32{ 1, 2 }, boundaryRange(s, 2, bt_char, .before));
    // word containing offset 5 ("two")
    try t.expectEqual([2]i32{ 4, 7 }, boundaryRange(s, 5, bt_word_start, .at));
    try t.expectEqualStrings("two", sliceChars(s, 4, 7));
    // the word before it
    const prev = boundaryRange(s, 5, bt_word_start, .before);
    try t.expectEqualStrings("one", sliceChars(s, prev[0], prev[1]));
    // line containing offset 2, INCLUDING its newline
    const line = boundaryRange(s, 2, bt_line_start, .at);
    try t.expectEqualStrings("one two\n", sliceChars(s, line[0], line[1]));
    // a sentence request degrades to the line rather than guessing
    try t.expectEqual(line, boundaryRange(s, 2, bt_sentence_start, .at));
    // empty text never produces a negative or inverted range
    try t.expectEqual([2]i32{ 0, 0 }, boundaryRange("", 0, bt_line_start, .at));
    try t.expectEqual([2]i32{ 0, 0 }, boundaryRange("", 5, bt_word_start, .after));
}

test "actionability follows role or focusability, and never a disabled node" {
    var n = axtree.Node{ .id = 1, .role = @constCast("button") };
    try t.expect(isActionable(&n));
    // A disabled control is not pressable whatever its role.
    n.state = proto.ax_disabled;
    try t.expect(!isActionable(&n));
    // A scripted div is actionable only because it is focusable.
    var d = axtree.Node{ .id = 2, .role = @constCast("generic") };
    try t.expect(!isActionable(&d));
    d.state = proto.ax_focusable;
    try t.expect(isActionable(&d));
}

test "node paths round-trip through the AT-SPI prefix" {
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings(PATH_PREFIX ++ "42", nodePath(&buf, 42));
    try t.expectEqual(@as(?usize, 1), indexOfId(&.{ 7, 9, 11 }, 9));
    try t.expectEqual(@as(?usize, null), indexOfId(&.{ 7, 9, 11 }, 8));
}

/// "unix:path=/x" or "unix:abstract=x" -> a connectable path ('@'
/// marks abstract, matching `busConnect`), copied into `buf`.
pub fn parseUnixPath(addr: []const u8, buf: []u8) ?[]const u8 {
    var seg = std.mem.splitScalar(u8, addr, ';');
    while (seg.next()) |part| {
        if (!std.mem.startsWith(u8, part, "unix:")) continue;
        var kv = std.mem.splitScalar(u8, part["unix:".len..], ',');
        while (kv.next()) |pair| {
            if (std.mem.startsWith(u8, pair, "path=")) {
                const p = pair["path=".len..];
                if (p.len > buf.len) return null;
                @memcpy(buf[0..p.len], p);
                return buf[0..p.len];
            }
            if (std.mem.startsWith(u8, pair, "abstract=")) {
                const p = pair["abstract=".len..];
                if (p.len + 1 > buf.len) return null;
                buf[0] = '@';
                @memcpy(buf[1 .. 1 + p.len], p);
                return buf[0 .. 1 + p.len];
            }
        }
    }
    return null;
}
