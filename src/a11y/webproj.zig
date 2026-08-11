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
//! SERVED (read-only v1): Accessible (role/name/state/children/
//! parent/attributes), Component (extents from the offset-container
//! chain, plus `setOrigin` for screen coordinates), Application on the
//! root, Properties, Peer.Ping, Cache.GetItems. NOT served yet, by
//! scope: object events (children-changed/state-changed emission),
//! focus/caret, Action/Text — a reader must re-walk to see updates.

const std = @import("std");
const c = @import("../c.zig").c;
const dbus = @import("../mux/dbus.zig");
const axtree = @import("../web/axtree.zig");
const proto = @import("../web/protocol.zig");

const ATSPI_ACCESSIBLE = "org.a11y.atspi.Accessible";
const ATSPI_COMPONENT = "org.a11y.atspi.Component";
const ATSPI_APPLICATION = "org.a11y.atspi.Application";
const PATH_PREFIX = "/org/a11y/atspi/accessible/";
const ROOT_PATH = "/org/a11y/atspi/accessible/root";
const CACHE_PATH = "/org/a11y/atspi/cache";
const NULL_PATH = "/org/a11y/atspi/null";
const REGISTRY_DEST = "org.a11y.atspi.Registry";

/// Total wall-clock budget for connect+auth+Embed.
const CONNECT_BUDGET_MS: i64 = 10_000;

fn nowMs() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return @as(i64, ts.tv_sec) * 1000 + @divTrunc(ts.tv_nsec, 1_000_000);
}

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

    pub fn init(gpa: std.mem.Allocator, tree: *axtree.Tree, app_name: []const u8) !Proj {
        return .{ .gpa = gpa, .tree = tree, .app_name = try gpa.dupe(u8, app_name) };
    }

    pub fn deinit(self: *Proj) void {
        if (self.fd >= 0) _ = c.close(self.fd);
        self.fd = -1;
        self.rbuf.deinit(self.gpa);
        self.gpa.free(self.app_name);
    }

    pub fn setOrigin(self: *Proj, x: i32, y: i32) void {
        self.origin_x = x;
        self.origin_y = y;
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
                try bw.putString(ATSPI_ACCESSIBLE);
                try bw.putString(ATSPI_COMPONENT);
                if (node == null) try bw.putString(ATSPI_APPLICATION);
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
                try bw.putBool(false); // read-only projection
                return true;
            }
            return false;
        }

        return false;
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
        try bw.putString(ATSPI_ACCESSIBLE);
        try bw.putString(ATSPI_COMPONENT);
        if (node == null) try bw.putString(ATSPI_APPLICATION);
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

fn busConnect(path: []const u8) !c_int {
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

fn waitFd(fd: c_int, events: c_short, deadline: i64) !void {
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

/// "unix:path=/x" or "unix:abstract=x" -> a connectable path ('@'
/// marks abstract, matching `busConnect`), copied into `buf`.
fn parseUnixPath(addr: []const u8, buf: []u8) ?[]const u8 {
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
