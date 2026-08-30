//! Ambient visibility of running assistants: what every `sketerm mcp`
//! on this machine is doing, watchable from this window by default.
//!
//! One discovery home. The MCP registry (`ipc/mcp_registry.zig`, flock
//! liveness) is watched with a GFileMonitor plus a slow fallback tick;
//! each live instance's private daemon is polled for its session
//! roster on a worker thread (a wedged daemon must never block the
//! main loop), and the result feeds three surfaces: the chip at the
//! end of the tab bar with its popover, the per-pane "AI attached"
//! chip's click, and the Session Overview's assistant daemons. The
//! Overview keeps its own per-daemon list fetch because it also covers
//! remote hosts; only the SCAN is unified here.
//!
//! Disappearance is normal, not an error: an isolated instance's
//! daemon retires after 120 s idle and a web session has a 60 s
//! no-client TTL, so entries simply leave the roster.
//!
//! Lifetimes: heap row contexts are owned by their button (mechanism
//! 1, `GDestroyNotify`); the popover is unparented by the chip's own
//! destroy handler; every worker handback and timer resolves through
//! the `dead` fence, and `stop` frees the watcher only once the last
//! worker has reported.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const mcp_registry = @import("../ipc/mcp_registry.zig");
const mux_client = @import("../mux/client.zig");
const mux_cli = @import("../ipc/mux_cli.zig");
const muxtabs = @import("muxtabs.zig");
const Window = @import("window.zig").Window;
const Pane = @import("pane.zig").Pane;

/// Slow fallback for a registry change the monitor missed (no GIO
/// backend, a lost inotify event) and the roster refresh cadence.
const TICK_MS: c_uint = 3000;
/// Coalesces the CREATED + CHANGED + lock events one registration emits.
const RESCAN_DEBOUNCE_MS: c_uint = 150;
/// Bound on one daemon's `list` reply; past it the daemon reads as
/// unavailable until the next tick.
const LIST_TIMEOUT_MS: i64 = 5_000;

/// What a session on an assistant's daemon is, for the icon and the
/// aggregate label. Derived from the daemon's own facts, never from
/// the assistant.
pub const Kind = enum {
    web,
    app,
    terminal,

    pub fn icon(self: Kind) [*:0]const u8 {
        return switch (self) {
            .web => "web-browser-symbolic",
            .app => "application-x-executable-symbolic",
            .terminal => "utilities-terminal-symbolic",
        };
    }

    fn noun(self: Kind, plural: bool) []const u8 {
        return switch (self) {
            .web => if (plural) "browsers" else "browser",
            .app => if (plural) "apps" else "app",
            .terminal => if (plural) "terminals" else "terminal",
        };
    }
};

/// `webdrive` names its browser session `web-<pid>-<hex>` and it is an
/// app session; every other app session is a launched application.
pub fn kindOf(name: []const u8, app: bool) Kind {
    if (!app) return .terminal;
    if (std.mem.startsWith(u8, name, "web-")) return .web;
    return .app;
}

pub const Session = struct {
    name: []u8,
    title: []u8,
    origin_id: []u8,
    kind: Kind,
    viewers: u32,

    fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.title);
        allocator.free(self.origin_id);
    }
};

pub const Assistant = struct {
    pid: c.pid_t,
    mode: mcp_registry.Mode,
    /// Never empty: the registry's display name, else `mcp <pid>`.
    name: []u8,
    /// Where it logs, or its profile; may be empty.
    detail: []u8,
    /// `sock:<mux socket>`, the host spec every attach path takes.
    host: []u8,
    sessions: std.ArrayList(Session) = .empty,
    /// A worker thread owns the connection; polls are serialized.
    busy: bool = false,
    /// Idle persistent connection reused by every poll and handed to an
    /// attach, exactly like the Overview's per-daemon connection.
    conn: ?mux_client.Conn = null,
    failed: bool = false,
    fingerprint: u64 = 0,
    /// Mark-and-sweep flag for a rescan.
    seen: bool = true,

    pub fn label(self: *const Assistant) []const u8 {
        return self.name;
    }

    fn deinit(self: *Assistant, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.detail);
        allocator.free(self.host);
        for (self.sessions.items) |*s| s.deinit(allocator);
        self.sessions.deinit(allocator);
        if (self.conn) |*conn| conn.deinit();
    }

    fn clearSessions(self: *Assistant, allocator: std.mem.Allocator) void {
        for (self.sessions.items) |*s| s.deinit(allocator);
        self.sessions.clearRetainingCapacity();
    }

    fn findSession(self: *Assistant, name: []const u8) ?*Session {
        for (self.sessions.items) |*s| if (std.mem.eql(u8, s.name, name)) return s;
        return null;
    }
};

/// Session counts by kind across every live assistant.
pub const Counts = struct {
    web: usize = 0,
    app: usize = 0,
    terminal: usize = 0,

    pub fn total(self: Counts) usize {
        return self.web + self.app + self.terminal;
    }

    pub fn add(self: *Counts, kind: Kind) void {
        switch (kind) {
            .web => self.web += 1,
            .app => self.app += 1,
            .terminal => self.terminal += 1,
        }
    }

    fn of(kind: Kind, counts: Counts) usize {
        return switch (kind) {
            .web => counts.web,
            .app => counts.app,
            .terminal => counts.terminal,
        };
    }

    /// `1 browser, 2 terminals` with zero kinds omitted; empty when
    /// nothing is running.
    pub fn describe(self: Counts, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var first = true;
        inline for (.{ Kind.web, Kind.app, Kind.terminal }) |kind| {
            const n = of(kind, self);
            if (n > 0) {
                if (!first) w.writeAll(", ") catch return w.buffered();
                first = false;
                w.print("{d} {s}", .{ n, kind.noun(n != 1) }) catch return w.buffered();
            }
        }
        return w.buffered();
    }
};

pub fn summarize(roster: []const Assistant) Counts {
    var counts: Counts = .{};
    for (roster) |a| for (a.sessions.items) |s| counts.add(s.kind);
    return counts;
}

/// The tab-bar chip text: `AI: 1 browser, 2 terminals`; an assistant
/// with no sessions yet still counts as present.
pub fn chipLabel(buf: []u8, live: usize, counts: Counts) []const u8 {
    if (live == 0) return "";
    var desc_buf: [96]u8 = undefined;
    const desc = counts.describe(&desc_buf);
    if (desc.len == 0) {
        return std.fmt.bufPrint(buf, "AI: {d} idle", .{live}) catch "AI";
    }
    return std.fmt.bufPrint(buf, "AI: {s}", .{desc}) catch "AI";
}

/// Icon and tooltip for each attach intent, shared by the tab-bar
/// popover and the Session Overview so the two never disagree.
pub const AttachVerb = struct { icon: [*:0]const u8, tip: [*:0]const u8, text: [*:0]const u8 };

pub fn attachVerb(lease: muxtabs.Lease) AttachVerb {
    return switch (lease) {
        .read_only => .{
            .icon = "view-reveal-symbolic",
            .tip = "Watch read-only - view the session without taking control of it",
            .text = "Watch",
        },
        .control, .default => .{
            .icon = "input-keyboard-symbolic",
            .tip = "Take control - attach and take the controller lease so your input reaches it",
            .text = "Take control",
        },
    };
}

/// Window-level registry watcher plus the tab-bar chip it drives.
pub const Watcher = struct {
    win: *Window,
    allocator: std.mem.Allocator,
    roster: std.ArrayList(Assistant) = .empty,
    monitor: ?*c.GFileMonitor = null,
    tick_id: c.guint = 0,
    rescan_id: c.guint = 0,
    pending_ops: usize = 0,
    dead: bool = false,
    chip: *c.GtkWidget,
    chip_label: *c.GtkWidget,
    popover: *c.GtkWidget,
    /// The assistant a pane chip asked for; ordered first in the popover.
    preferred_pid: c.pid_t = 0,
    /// The chip's widget tree was disposed (the window closed): no
    /// label, popover or tooltip may be touched again. `Window.deinit`
    /// (and so `stop`) runs on a LATER idle than the widget destroy
    /// chain, which is why this is a flag and not an ordering rule.
    widgets_dead: bool = false,

    /// Create the chip at the end of the window's tab bar and start
    /// watching. Null when the registry directory cannot exist or the
    /// chip cannot be built; the window then simply has no ambient
    /// assistant surface.
    pub fn start(win: *Window) ?*Watcher {
        const allocator = win.allocator;
        const self = allocator.create(Watcher) catch return null;
        const chip = c.gtk_button_new() orelse {
            allocator.destroy(self);
            return null;
        };
        const chip_label = c.gtk_label_new("").?;
        c.gtk_button_set_child(@ptrCast(chip), chip_label);
        c.gtk_widget_add_css_class(chip, "flat");
        c.gtk_widget_add_css_class(chip, "sketerm-assistant-chip");
        c.gtk_widget_set_valign(chip, c.GTK_ALIGN_CENTER);
        c.gtk_widget_set_can_focus(chip, 0);
        c.gtk_widget_set_visible(chip, 0);
        const popover = c.gtk_popover_new() orelse {
            _ = c.g_object_ref_sink(chip);
            c.g_object_unref(chip);
            allocator.destroy(self);
            return null;
        };
        c.gtk_widget_set_parent(popover, chip);
        c.gtk_popover_set_position(@ptrCast(popover), c.GTK_POS_BOTTOM);
        self.* = .{
            .win = win,
            .allocator = allocator,
            .chip = chip,
            .chip_label = chip_label,
            .popover = popover,
        };
        // The popover is a child of the chip and must be unparented in
        // the chip's dispose; a tiny context owned by that connection
        // (GDestroyNotify) does it whether the window or a theme swap
        // destroys the strip, without needing the watcher alive.
        const unparent = allocator.create(UnparentCtx) catch {
            c.gtk_widget_unparent(popover);
            _ = c.g_object_ref_sink(chip);
            c.g_object_unref(chip);
            allocator.destroy(self);
            return null;
        };
        unparent.* = .{ .allocator = allocator, .popover = popover, .watcher = self };
        _ = c.g_signal_connect_data(chip, "destroy", @ptrCast(&onChipDestroy), @ptrCast(unparent), @ptrCast(cast.destroyCtx(UnparentCtx)), c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(chip, "clicked", @ptrCast(&onChipClicked), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
        win.tabbar.appendEnd(chip);
        // Our own reference: `stop` runs from the deferred window free,
        // after the tab bar has disposed the chip, and the disconnect
        // there must target a live GObject, never a finalized one.
        _ = c.g_object_ref(@ptrCast(chip));
        self.arm();
        self.tick_id = c.g_timeout_add(TICK_MS, @ptrCast(&onTick), @ptrCast(self));
        self.rescan();
        return self;
    }

    /// Stop watching. Widgets are left to the window's own teardown;
    /// the struct is freed once no worker can still report into it.
    pub fn stop(self: *Watcher) void {
        self.dead = true;
        if (self.tick_id != 0) {
            _ = c.g_source_remove(self.tick_id);
            self.tick_id = 0;
        }
        if (self.rescan_id != 0) {
            _ = c.g_source_remove(self.rescan_id);
            self.rescan_id = 0;
        }
        self.disarm();
        _ = c.g_signal_handlers_disconnect_matched(@ptrCast(self.chip), @intCast(c.G_SIGNAL_MATCH_DATA), 0, 0, null, null, @ptrCast(self));
        c.g_object_unref(@ptrCast(self.chip));
        self.freeRoster();
        if (self.pending_ops == 0) self.allocator.destroy(self);
    }

    fn freeRoster(self: *Watcher) void {
        for (self.roster.items) |*a| a.deinit(self.allocator);
        self.roster.deinit(self.allocator);
        self.roster = .empty;
    }

    fn opDone(self: *Watcher) bool {
        self.pending_ops -= 1;
        if (self.dead and self.pending_ops == 0) {
            self.allocator.destroy(self);
            return false;
        }
        return true;
    }

    fn arm(self: *Watcher) void {
        const dir = mcp_registry.ensureDir() catch return;
        var z: [4096:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&z, "{s}", .{dir}) catch return;
        const file = c.g_file_new_for_path(path.ptr) orelse return;
        defer c.g_object_unref(@ptrCast(file));
        const mon = c.g_file_monitor_directory(file, c.G_FILE_MONITOR_NONE, null, null) orelse return;
        self.monitor = mon;
        _ = c.g_signal_connect_data(@ptrCast(mon), "changed", @ptrCast(&onDirChanged), @ptrCast(self), null, c.G_CONNECT_DEFAULT);
    }

    fn disarm(self: *Watcher) void {
        const mon = self.monitor orelse return;
        _ = c.g_signal_handlers_disconnect_matched(@ptrCast(mon), @intCast(c.G_SIGNAL_MATCH_DATA), 0, 0, null, null, @ptrCast(self));
        _ = c.g_file_monitor_cancel(mon);
        c.g_object_unref(@ptrCast(mon));
        self.monitor = null;
    }

    fn findByPid(self: *Watcher, pid: c.pid_t) ?*Assistant {
        for (self.roster.items) |*a| if (a.pid == pid) return a;
        return null;
    }

    fn findByHost(self: *Watcher, host: []const u8) ?*Assistant {
        for (self.roster.items) |*a| if (std.mem.eql(u8, a.host, host)) return a;
        return null;
    }

    /// Re-list the registry: add newcomers, drop the departed, then
    /// poll every idle daemon for its roster.
    fn rescan(self: *Watcher) void {
        if (self.dead) return;
        const entries = mcp_registry.list(self.allocator, true) catch return;
        defer mcp_registry.freeEntries(self.allocator, entries);
        for (self.roster.items) |*a| a.seen = false;
        var changed = false;
        for (entries) |entry| {
            if (self.findByPid(entry.pid)) |a| {
                a.seen = true;
                continue;
            }
            if (self.addAssistant(entry)) changed = true;
        }
        var i: usize = 0;
        while (i < self.roster.items.len) {
            const a = &self.roster.items[i];
            if (a.seen or a.busy) {
                i += 1;
                continue;
            }
            var gone = self.roster.swapRemove(i);
            gone.deinit(self.allocator);
            changed = true;
        }
        if (changed) self.refreshChip();
        for (self.roster.items) |*a| self.startFetch(a);
    }

    fn addAssistant(self: *Watcher, entry: mcp_registry.Entry) bool {
        self.addAssistantOrError(entry) catch return false;
        return true;
    }

    fn addAssistantOrError(self: *Watcher, entry: mcp_registry.Entry) !void {
        const allocator = self.allocator;
        var name_buf: [48]u8 = undefined;
        const shown = entry.displayName();
        const name_src = if (shown.len > 0) shown else std.fmt.bufPrint(&name_buf, "mcp {d}", .{entry.pid}) catch "mcp";
        const name = try allocator.dupe(u8, name_src);
        errdefer allocator.free(name);
        const detail_src = if (entry.log_dir.len > 0) entry.log_dir else entry.profile;
        const detail = try allocator.dupe(u8, detail_src);
        errdefer allocator.free(detail);
        const host = try std.fmt.allocPrint(allocator, "sock:{s}", .{entry.mux_socket});
        errdefer allocator.free(host);
        try self.roster.append(allocator, .{
            .pid = entry.pid,
            .mode = entry.mode,
            .name = name,
            .detail = detail,
            .host = host,
        });
    }

    /// Paint the chip from the roster. Hidden while nothing is live.
    fn refreshChip(self: *Watcher) void {
        if (self.dead or self.widgets_dead) return;
        var buf: [128:0]u8 = undefined;
        const text = chipLabel(buf[0 .. buf.len - 1], self.roster.items.len, summarize(self.roster.items));
        if (text.len == 0) {
            c.gtk_widget_set_visible(self.chip, 0);
            if (c.gtk_widget_get_visible(self.popover) != 0) c.gtk_popover_popdown(@ptrCast(self.popover));
            return;
        }
        buf[text.len] = 0;
        c.gtk_label_set_text(@ptrCast(self.chip_label), buf[0..text.len :0].ptr);
        var tip: [1024:0]u8 = undefined;
        var w: std.Io.Writer = .fixed(tip[0 .. tip.len - 1]);
        for (self.roster.items) |a| {
            var counts: Counts = .{};
            for (a.sessions.items) |s| counts.add(s.kind);
            var desc_buf: [96]u8 = undefined;
            const desc = counts.describe(&desc_buf);
            w.print("{s}: {s}{s}\n", .{ a.label(), if (desc.len > 0) desc else "idle", if (a.failed) " (daemon unreachable)" else "" }) catch break;
        }
        const n = w.buffered().len;
        tip[n] = 0;
        c.gtk_widget_set_tooltip_text(self.chip, tip[0..n :0].ptr);
        c.gtk_widget_set_visible(self.chip, 1);
        if (c.gtk_widget_get_visible(self.popover) != 0) self.buildPopover();
    }

    /// Open the popover, ordering `preferred` first when it names a
    /// live assistant. Falls back to the Session Overview when the tab
    /// bar (and so the chip) is hidden.
    pub fn open(self: *Watcher, preferred: c.pid_t) void {
        if (self.dead or self.widgets_dead) return;
        self.preferred_pid = preferred;
        if (c.gtk_widget_get_mapped(self.chip) == 0) {
            @import("app_switcher.zig").open(self.win);
            return;
        }
        self.buildPopover();
        c.gtk_popover_popup(@ptrCast(self.popover));
    }

    fn buildPopover(self: *Watcher) void {
        const pop: *c.GtkPopover = @ptrCast(self.popover);
        c.gtk_popover_set_child(pop, null);
        const root = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8).?;
        c.gtk_widget_set_margin_start(root, 6);
        c.gtk_widget_set_margin_end(root, 6);
        c.gtk_widget_set_margin_top(root, 6);
        c.gtk_widget_set_margin_bottom(root, 6);
        // Preferred assistant first, then registry order.
        if (self.findByPid(self.preferred_pid)) |a| self.appendAssistant(root, a);
        for (self.roster.items) |*a| {
            if (a.pid == self.preferred_pid) continue;
            self.appendAssistant(root, a);
        }
        if (self.roster.items.len == 0) {
            const none = c.gtk_label_new("No assistant is running.").?;
            c.gtk_widget_add_css_class(none, "dim-label");
            c.gtk_box_append(@ptrCast(root), none);
        }
        c.gtk_popover_set_child(pop, root);
    }

    fn appendAssistant(self: *Watcher, root: *c.GtkWidget, a: *Assistant) void {
        const section = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 2).?;
        var head_buf: [256:0]u8 = undefined;
        const head = std.fmt.bufPrintZ(&head_buf, "{s}", .{a.label()}) catch "assistant";
        const head_label = c.gtk_label_new(head.ptr).?;
        c.gtk_label_set_xalign(@ptrCast(head_label), 0);
        c.gtk_widget_add_css_class(head_label, "heading");
        c.gtk_box_append(@ptrCast(section), head_label);
        var sub_buf: [512:0]u8 = undefined;
        const sub = std.fmt.bufPrintZ(&sub_buf, "{s}{s}{s}", .{
            a.mode.text(),
            if (a.detail.len > 0) " - " else "",
            a.detail,
        }) catch "";
        const sub_label = c.gtk_label_new(sub.ptr).?;
        c.gtk_label_set_xalign(@ptrCast(sub_label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(sub_label), c.PANGO_ELLIPSIZE_MIDDLE);
        c.gtk_label_set_max_width_chars(@ptrCast(sub_label), 48);
        c.gtk_widget_add_css_class(sub_label, "dim-label");
        c.gtk_box_append(@ptrCast(section), sub_label);
        if (a.sessions.items.len == 0) {
            const idle = c.gtk_label_new(if (a.failed) "daemon unreachable" else "no sessions yet").?;
            c.gtk_label_set_xalign(@ptrCast(idle), 0);
            c.gtk_widget_add_css_class(idle, "dim-label");
            c.gtk_box_append(@ptrCast(section), idle);
        }
        for (a.sessions.items) |*s| self.appendSessionRow(section, a, s);
        c.gtk_box_append(@ptrCast(root), section);
    }

    fn appendSessionRow(self: *Watcher, section: *c.GtkWidget, a: *Assistant, s: *Session) void {
        const row = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 6).?;
        const icon = c.gtk_image_new_from_icon_name(s.kind.icon()).?;
        c.gtk_box_append(@ptrCast(row), icon);
        var text_buf: [320:0]u8 = undefined;
        const text = std.fmt.bufPrintZ(&text_buf, "{s}", .{if (s.title.len > 0) s.title else s.name}) catch "session";
        const label = c.gtk_label_new(text.ptr).?;
        c.gtk_label_set_xalign(@ptrCast(label), 0);
        c.gtk_label_set_ellipsize(@ptrCast(label), c.PANGO_ELLIPSIZE_END);
        c.gtk_label_set_max_width_chars(@ptrCast(label), 36);
        c.gtk_widget_set_hexpand(label, 1);
        var tip_buf: [400:0]u8 = undefined;
        const tip = std.fmt.bufPrintZ(&tip_buf, "{s} ({s}), {d} viewer(s)", .{ s.name, @tagName(s.kind), s.viewers }) catch null;
        if (tip) |tz| c.gtk_widget_set_tooltip_text(label, tz.ptr);
        c.gtk_box_append(@ptrCast(row), label);
        const shown = self.win.sessionShown(s.name, a.host);
        for ([_]muxtabs.Lease{ .read_only, .control }) |lease| {
            const verb = attachVerb(lease);
            // Labelled, not icon-only: the popover is the one place a
            // person reads these verbs cold, and a rig drives them by text.
            const btn = c.gtk_button_new_with_label(verb.text).?;
            c.gtk_widget_add_css_class(btn, "flat");
            c.gtk_widget_set_tooltip_text(btn, verb.tip);
            // A session already in this window is not attached twice
            // from here; the pane's own chip escalates the lease.
            c.gtk_widget_set_sensitive(btn, @intFromBool(!shown));
            const ctx = self.allocator.create(RowCtx) catch continue;
            ctx.* = .{
                .allocator = self.allocator,
                .watcher = self,
                .pid = a.pid,
                .session = self.allocator.dupe(u8, s.name) catch {
                    self.allocator.destroy(ctx);
                    continue;
                },
                .lease = lease,
            };
            _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onRowClicked), @ptrCast(ctx), @ptrCast(&freeRowCtx), c.G_CONNECT_DEFAULT);
            c.gtk_box_append(@ptrCast(row), btn);
        }
        c.gtk_box_append(@ptrCast(section), row);
    }

    /// Attach `session` of the assistant `pid` into this window with
    /// `lease`, off-thread; the popover closes when the attach lands.
    fn startAttach(self: *Watcher, pid: c.pid_t, session: []const u8, lease: muxtabs.Lease) void {
        if (self.dead) return;
        const a = self.findByPid(pid) orelse return;
        const target = a.findSession(session) orelse return;
        var reuse: ?mux_client.Conn = null;
        if (!a.busy) {
            if (a.conn) |conn| {
                reuse = conn;
                a.conn = null;
            }
        }
        if (!muxtabs.AttachJob.start(self.win, a.host, session, target.origin_id, lease, .tab, reuse, onAttachReady, @ptrCast(self))) {
            if (reuse) |*conn| conn.deinit();
            return;
        }
        self.pending_ops += 1;
    }

    /// Poll one assistant's daemon for its sessions (worker thread).
    fn startFetch(self: *Watcher, a: *Assistant) void {
        if (a.busy) return;
        const allocator = std.heap.c_allocator;
        const op = allocator.create(FetchOp) catch return;
        op.* = .{ .watcher = self, .pid = a.pid, .path = null };
        op.path = allocator.dupe(u8, a.host["sock:".len..]) catch {
            allocator.destroy(op);
            return;
        };
        if (a.conn) |conn| {
            op.conn = conn;
            a.conn = null;
        }
        const thread = std.Thread.spawn(.{}, fetchThreadMain, .{op}) catch {
            // Nothing started: hand the connection back untouched.
            if (op.conn) |conn| a.conn = conn;
            op.conn = null;
            op.destroy();
            return;
        };
        thread.detach();
        a.busy = true;
        self.pending_ops += 1;
    }

    /// Apply a finished poll. `changed` drives one chip repaint.
    fn applyFetch(self: *Watcher, op: *FetchOp) void {
        const a = self.findByPid(op.pid) orelse return;
        a.busy = false;
        if (op.ok) {
            if (op.conn) |conn| {
                a.conn = conn;
                op.conn = null;
            }
        }
        const failed = !op.ok;
        var changed = a.failed != failed;
        a.failed = failed;
        if (op.parsed) |parsed| {
            const fp = rosterFingerprint(parsed.value.sessions);
            if (fp != a.fingerprint or a.sessions.items.len == 0) {
                a.fingerprint = fp;
                a.clearSessions(self.allocator);
                for (parsed.value.sessions) |info| {
                    if (info.exited) continue;
                    // Out of memory mid-roster: show what fit; the next
                    // poll's fingerprint differs from nothing and retries.
                    self.appendSession(a, info) catch {
                        a.fingerprint = 0;
                        break;
                    };
                }
                changed = true;
            }
        }
        if (changed) self.refreshChip();
    }

    fn appendSession(self: *Watcher, a: *Assistant, info: mux_cli.SessionInfo) !void {
        const allocator = self.allocator;
        const name = try allocator.dupe(u8, info.name);
        errdefer allocator.free(name);
        const title = try allocator.dupe(u8, info.title);
        errdefer allocator.free(title);
        const origin_id = try allocator.dupe(u8, info.origin_id);
        errdefer allocator.free(origin_id);
        try a.sessions.append(allocator, .{
            .name = name,
            .title = title,
            .origin_id = origin_id,
            .kind = kindOf(info.name, info.app),
            .viewers = info.viewerCount(),
        });
    }
};

/// Owned by the chip's destroy connection; unparents the popover at
/// the only correct moment, the chip's own dispose.
const UnparentCtx = struct {
    allocator: std.mem.Allocator,
    popover: *c.GtkWidget,
    /// Alive whenever the chip is: the watcher holds a reference on
    /// the chip and releases it only inside `stop`, before freeing itself.
    watcher: *Watcher,
};

fn onChipDestroy(_: *c.GtkWidget, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(UnparentCtx, user);
    ctx.watcher.widgets_dead = true;
    c.gtk_widget_unparent(ctx.popover);
}

fn onChipClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Watcher, user);
    self.open(0);
}

const RowCtx = struct {
    allocator: std.mem.Allocator,
    watcher: *Watcher,
    pid: c.pid_t,
    session: []u8,
    lease: muxtabs.Lease,
};

fn freeRowCtx(user: ?*anyopaque, _: ?*c.GClosure) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    ctx.allocator.free(ctx.session);
    ctx.allocator.destroy(ctx);
}

fn onRowClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(RowCtx, user);
    // The popover is rebuilt while it is open, which frees this row's
    // button and with it this context: copy what the attach needs
    // before anything can rebuild.
    const watcher = ctx.watcher;
    const pid = ctx.pid;
    const lease = ctx.lease;
    var name_buf: [256]u8 = undefined;
    const n = @min(ctx.session.len, name_buf.len);
    @memcpy(name_buf[0..n], ctx.session[0..n]);
    watcher.startAttach(pid, name_buf[0..n], lease);
}

fn onAttachReady(user: ?*anyopaque, job: *muxtabs.AttachJob) void {
    const self = cast.userData(Watcher, user);
    const alive = !self.dead and !self.widgets_dead;
    if (alive) {
        if (job.finish()) {
            c.gtk_popover_popdown(@ptrCast(self.popover));
        }
    }
    if (!self.opDone()) return;
    if (alive) self.refreshChip();
}

fn onDirChanged(_: ?*c.GFileMonitor, _: ?*c.GFile, _: ?*c.GFile, _: c.GFileMonitorEvent, user: ?*anyopaque) callconv(.c) void {
    const self = cast.userData(Watcher, user);
    if (self.dead) return;
    if (self.rescan_id != 0) _ = c.g_source_remove(self.rescan_id);
    self.rescan_id = c.g_timeout_add(RESCAN_DEBOUNCE_MS, @ptrCast(&onRescanTimer), @ptrCast(self));
}

fn onRescanTimer(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Watcher, user);
    self.rescan_id = 0;
    if (!self.dead) self.rescan();
    return 0;
}

fn onTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self = cast.userData(Watcher, user);
    if (self.dead) return 0;
    self.rescan();
    return 1;
}

/// One roster poll of one assistant daemon; lives on the C heap so the
/// worker thread and the idle handback share it without the window
/// allocator.
const FetchOp = struct {
    watcher: *Watcher,
    pid: c.pid_t,
    path: ?[]u8,
    conn: ?mux_client.Conn = null,
    parsed: ?std.json.Parsed(mux_cli.Welcome) = null,
    ok: bool = false,

    fn destroy(self: *FetchOp) void {
        const allocator = std.heap.c_allocator;
        if (self.conn) |*conn| conn.deinit();
        if (self.parsed) |*parsed| parsed.deinit();
        if (self.path) |path| allocator.free(path);
        allocator.destroy(self);
    }
};

fn fetchThreadMain(op: *FetchOp) void {
    const reused = op.conn != null;
    if (op.conn == null) op.conn = dialSocket(op.path.?);
    if (op.conn != null and !runList(op) and reused) {
        // The idle connection died between polls (daemon retired and
        // came back): one fresh dial, then give up until the next tick.
        op.conn.?.deinit();
        op.conn = dialSocket(op.path.?);
        if (op.conn != null) _ = runList(op);
    }
    _ = c.g_idle_add(@ptrCast(&onFetchIdle), @ptrCast(op));
}

/// Connect-only: a dead assistant daemon is never resurrected by a
/// viewer, and its absence is silent (the roster shows it unreachable).
fn dialSocket(path: []const u8) ?mux_client.Conn {
    var conn = mux_client.Conn.connectProbed(std.heap.c_allocator, path) catch return null;
    conn.setNonBlocking();
    return conn;
}

fn runList(op: *FetchOp) bool {
    const allocator = std.heap.c_allocator;
    const conn = &op.conn.?;
    conn.sendFrame(.list, "") catch return false;
    const f = conn.recvExpectFor(&.{.welcome}, LIST_TIMEOUT_MS) catch return false;
    defer f.deinit(allocator);
    if (op.parsed) |*old| {
        old.deinit();
        op.parsed = null;
    }
    op.parsed = std.json.parseFromSlice(mux_cli.Welcome, allocator, f.payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return false;
    op.ok = true;
    return true;
}

fn onFetchIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const op = cast.userData(FetchOp, user);
    const self = op.watcher;
    if (!self.dead) self.applyFetch(op);
    op.destroy();
    _ = self.opDone();
    return 0;
}

fn rosterFingerprint(sessions: []const mux_cli.SessionInfo) u64 {
    var hash: u64 = 0;
    for (sessions) |s| {
        hash = std.hash.Wyhash.hash(hash, s.name);
        hash = std.hash.Wyhash.hash(hash, s.title);
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&s.exited));
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&s.app));
        const viewers = s.viewerCount();
        hash = std.hash.Wyhash.hash(hash, std.mem.asBytes(&viewers));
    }
    return hash;
}

/// The per-pane "AI attached" chip was clicked: open the surface
/// scoped to the assistant whose daemon hosts that pane's session when
/// there is one, else unscoped.
pub fn openForPane(win: *Window, pane: *Pane) void {
    const watcher = win.assistants orelse {
        @import("app_switcher.zig").open(win);
        return;
    };
    var preferred: c.pid_t = 0;
    if (pane.terminal.remote) |remote| {
        if (remote.host) |host| {
            if (watcher.findByHost(host)) |a| preferred = a.pid;
        }
    }
    watcher.open(preferred);
}

// --- tests ------------------------------------------------------

const t = std.testing;

test "session kinds derive from the daemon's facts" {
    try t.expectEqual(Kind.terminal, kindOf("s1234-1", false));
    try t.expectEqual(Kind.terminal, kindOf("web-1-abc", false));
    try t.expectEqual(Kind.web, kindOf("web-2888490-28c86295", true));
    try t.expectEqual(Kind.app, kindOf("launch-3", true));
}

test "chip label aggregates every assistant and omits zero kinds" {
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings("", chipLabel(&buf, 0, .{}));
    try t.expectEqualStrings("AI: 1 idle", chipLabel(&buf, 1, .{}));
    try t.expectEqualStrings("AI: 1 browser", chipLabel(&buf, 1, .{ .web = 1 }));
    try t.expectEqualStrings("AI: 1 browser, 2 terminals", chipLabel(&buf, 2, .{ .web = 1, .terminal = 2 }));
    try t.expectEqualStrings("AI: 2 apps, 1 terminal", chipLabel(&buf, 1, .{ .app = 2, .terminal = 1 }));
}

test "summarize counts sessions across the roster" {
    const a = t.allocator;
    var roster: [2]Assistant = undefined;
    for (&roster, 0..) |*r, i| {
        r.* = .{
            .pid = @intCast(i + 1),
            .mode = .isolated,
            .name = try a.dupe(u8, "mcp"),
            .detail = try a.dupe(u8, ""),
            .host = try a.dupe(u8, "sock:/tmp/x"),
        };
    }
    defer for (&roster) |*r| r.deinit(a);
    const kinds = [_]struct { idx: usize, kind: Kind }{
        .{ .idx = 0, .kind = .web },
        .{ .idx = 1, .kind = .terminal },
        .{ .idx = 1, .kind = .terminal },
    };
    for (kinds) |k| {
        try roster[k.idx].sessions.append(a, .{
            .name = try a.dupe(u8, "s"),
            .title = try a.dupe(u8, ""),
            .origin_id = try a.dupe(u8, ""),
            .kind = k.kind,
            .viewers = 0,
        });
    }
    const counts = summarize(&roster);
    try t.expectEqual(@as(usize, 1), counts.web);
    try t.expectEqual(@as(usize, 0), counts.app);
    try t.expectEqual(@as(usize, 2), counts.terminal);
    try t.expectEqual(@as(usize, 3), counts.total());
}

test "attach verbs give watch and control distinct icons" {
    try t.expect(attachVerb(.read_only).icon != attachVerb(.control).icon);
    try t.expectEqualStrings("Watch", std.mem.span(attachVerb(.read_only).text));
    try t.expectEqualStrings("Take control", std.mem.span(attachVerb(.control).text));
}
