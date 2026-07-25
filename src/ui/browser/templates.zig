//! New from Template: the host's freedesktop `Templates` directory as
//! a New-menu submenu.
//!
//! The directory itself is resolved by the DAEMON that owns the files
//! (the `homedir` reply carries it), and listed over the same
//! connection, so a remote tab offers that machine's templates rather
//! than the local machine's. Instantiating one is an ordinary copy
//! job, which makes it undoable like every other copy.

const std = @import("std");
const c = @import("../../c.zig").c;

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const HostConn = @import("types.zig").HostConn;
const WireReply = @import("types.zig").WireReply;
const connectPopoverAutoUnparent = @import("menu.zig").connectPopoverAutoUnparent;
const copyZ = @import("../../filebrowser/format.zig").copyZN;
const uniqueDstName = @import("ops.zig").uniqueDstName;

/// Cap on the entries a template menu shows. A Templates directory is
/// a hand-curated place; a huge one is a mistake, not a use case.
const MAX_TEMPLATES: usize = 64;

/// The one in-flight template lookup and the popover it fills. At most
/// one is open, so this is a single optional rather than a list. The
/// popover is held with an OWN reference: the tab it is parented to
/// can be closed while a reply is still on its way.
pub const State = struct {
    /// Which host and tab the open menu belongs to.
    hc: ?*HostConn = null,
    tab: ?*BTab = null,
    /// The menu opened before the connection's one `homedir` reply
    /// landed; conn.zig calls onHostDirs when it does. This module
    /// does NOT issue that request itself -- conn.zig owns the one
    /// per HostConn, sent as soon as the connection is live.
    awaiting_dirs: bool = false,
    /// Awaiting the Templates directory listing.
    list_req: u32 = 0,
    popover: ?*c.GtkWidget = null,
    box: ?*c.GtkWidget = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        _ = allocator;
        if (self.popover) |popover| c.g_object_unref(@ptrCast(popover));
        self.* = .{};
    }
};

/// Heap context for one template row, freed with its button.
const PickCtx = struct {
    allocator: std.mem.Allocator,
    view: *BrowserView,
    tab: *BTab,
    /// Full path of the template file on the tab's host (owned).
    source: []u8,

    fn free(user: ?*anyopaque, closure: ?*anyopaque) callconv(.c) void {
        _ = closure;
        const ctx: *PickCtx = @ptrCast(@alignCast(user.?));
        ctx.allocator.free(ctx.source);
        ctx.allocator.destroy(ctx);
    }
};

/// Open the New-from-Template menu for `tab`. The popover appears
/// immediately with a "loading" row and fills itself in; the lookup is
/// two round trips at most and never blocks the loop.
pub fn showTemplateMenu(self: *BrowserView, tab: *BTab) void {
    closeMenu(self);
    const hc = tab.hc;
    if (hc.state != .ready) {
        self.setStatusFmt("not connected to {s}", .{hc.label()});
        return;
    }
    const popover = c.gtk_popover_new();
    const box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 0);
    c.gtk_widget_set_margin_start(box, 8);
    c.gtk_widget_set_margin_end(box, 8);
    c.gtk_widget_set_margin_top(box, 8);
    c.gtk_widget_set_margin_bottom(box, 8);
    c.gtk_box_append(@ptrCast(box), c.gtk_label_new("Looking for templates…"));
    c.gtk_popover_set_child(@ptrCast(popover), box);
    // Our own reference; released by closeMenu or State.deinit.
    _ = c.g_object_ref_sink(@ptrCast(popover));
    c.gtk_widget_set_parent(popover, tab.page);
    connectPopoverAutoUnparent(popover);
    const rect = c.GdkRectangle{ .x = 40, .y = 40, .width = 1, .height = 1 };
    c.gtk_popover_set_pointing_to(@ptrCast(popover), &rect);
    c.gtk_popover_popup(@ptrCast(popover));

    self.templates = .{ .hc = hc, .tab = tab, .popover = popover, .box = box };
    if (hc.templates_dir != null) {
        requestListing(self, hc);
    } else if (hc.dirs_known) {
        // The host already answered and reported none: no further
        // reply is coming, so say so instead of waiting forever.
        setMessage(self, "this host reports no template directory");
    } else {
        self.templates.awaiting_dirs = true;
        self.requestHostDirs(hc);
    }
}

/// The connection's `homedir` reply landed: continue a menu that was
/// waiting for this host's Templates directory.
pub fn onHostDirs(self: *BrowserView, hc: *HostConn) void {
    const state = &self.templates;
    if (!state.awaiting_dirs or state.hc != hc) return;
    state.awaiting_dirs = false;
    if (hc.templates_dir == null)
        return setMessage(self, "this host reports no template directory");
    requestListing(self, hc);
}

fn requestListing(self: *BrowserView, hc: *HostConn) void {
    const dir = hc.templates_dir orelse return;
    self.templates.list_req = self.nextReq();
    self.sendOp(hc, .{ .req = self.templates.list_req, .op = "list", .path = dir });
}

fn closeMenu(self: *BrowserView) void {
    if (self.templates.popover) |popover| {
        c.gtk_popover_popdown(@ptrCast(popover));
        c.g_object_unref(@ptrCast(popover));
    }
    self.templates = .{};
}

fn setMessage(self: *BrowserView, text: [*:0]const u8) void {
    const box = self.templates.box orelse return;
    while (c.gtk_widget_get_first_child(box)) |child| {
        c.gtk_box_remove(@ptrCast(box), child);
    }
    const label = c.gtk_label_new(text);
    c.gtk_label_set_xalign(@ptrCast(label), 0);
    c.gtk_widget_add_css_class(label, "dim-label");
    c.gtk_box_append(@ptrCast(box), label);
}

/// Route the Templates listing reply that belongs to the open menu.
/// The `homedir` reply that precedes it is conn.zig's, and arrives
/// here as onHostDirs.
/// @return true when the reply was ours.
pub fn feedTemplates(self: *BrowserView, hc: *HostConn, rep: WireReply) bool {
    const state = &self.templates;
    if (state.hc != hc) return false;
    if (state.list_req != 0 and state.list_req == rep.req) {
        if (!rep.ok) {
            state.list_req = 0;
            var z: [4300:0]u8 = undefined;
            var buf: [4200]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "no templates: {s} ({s})", .{
                hc.templates_dir orelse "?", rep.@"error",
            }) catch "no templates on this host";
            setMessage(self, copyZ(&z, text));
            return true;
        }
        populate(self, hc, rep);
        // A chunked listing keeps the request open until the last one.
        if (!rep.more) state.list_req = 0;
        return true;
    }
    return false;
}

fn populate(self: *BrowserView, hc: *HostConn, rep: WireReply) void {
    const state = &self.templates;
    const box = state.box orelse return;
    const tab = state.tab orelse return;
    // The tab can be closed while the listing is on its way.
    if (!self.tabAlive(tab)) return closeMenu(self);
    const dir = hc.templates_dir orelse return;
    // The placeholder row goes on the first chunk only.
    if (state.list_req != 0 and c.gtk_widget_get_first_child(box) != null) {
        var only_placeholder = true;
        var child = c.gtk_widget_get_first_child(box);
        while (child) |w| : (child = c.gtk_widget_get_next_sibling(w)) {
            if (c.g_object_get_data(@ptrCast(w), "sketerm-template") != null) only_placeholder = false;
        }
        if (only_placeholder) {
            while (c.gtk_widget_get_first_child(box)) |first| c.gtk_box_remove(@ptrCast(box), first);
        }
    }
    var shown: usize = 0;
    for (rep.entries) |e| {
        if (shown >= MAX_TEMPLATES) break;
        if (e.name.len == 0 or e.name[0] == '.') continue;
        var path_buf: [4300]u8 = undefined;
        const source = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{
            if (dir.len == 1) "" else dir, e.name,
        }) catch continue;
        const ctx = self.allocator.create(PickCtx) catch continue;
        ctx.* = .{
            .allocator = self.allocator,
            .view = self,
            .tab = tab,
            .source = self.allocator.dupe(u8, source) catch {
                self.allocator.destroy(ctx);
                continue;
            },
        };
        var z: [512:0]u8 = undefined;
        const btn = c.gtk_button_new_with_label(copyZ(&z, e.name));
        c.gtk_button_set_has_frame(@ptrCast(btn), 0);
        c.gtk_widget_set_halign(c.gtk_button_get_child(@ptrCast(btn)), c.GTK_ALIGN_START);
        c.g_object_set_data(@ptrCast(btn), "sketerm-template", @ptrCast(btn));
        _ = c.g_signal_connect_data(btn, "clicked", @ptrCast(&onPick), @ptrCast(ctx), @ptrCast(&PickCtx.free), c.G_CONNECT_DEFAULT);
        c.gtk_box_append(@ptrCast(box), btn);
        shown += 1;
    }
    if (shown == 0 and !rep.more and c.gtk_widget_get_first_child(box) == null) {
        var z: [4300:0]u8 = undefined;
        var buf: [4200]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} is empty", .{dir}) catch "no templates on this host";
        setMessage(self, copyZ(&z, text));
    }
}

fn onPick(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const ctx: *PickCtx = @ptrCast(@alignCast(user.?));
    const self = ctx.view;
    const tab = ctx.tab;
    // The button dies with the popover, so copy what is needed out
    // before popping it down.
    var src_buf: [4300]u8 = undefined;
    if (ctx.source.len >= src_buf.len) return;
    @memcpy(src_buf[0..ctx.source.len], ctx.source);
    const source = src_buf[0..ctx.source.len];
    closeMenu(self);
    instantiate(self, tab, source);
}

/// Copy one template into the tab's directory under a free name. It is
/// a plain copy job, so it lands in the jobs panel and on the undo
/// stack like any other.
pub fn instantiate(self: *BrowserView, tab: *BTab, source: []const u8) void {
    if (!self.tabAlive(tab)) return;
    const base = std.fs.path.basename(source);
    var name_buf: [512]u8 = undefined;
    var name: []const u8 = base;
    if (tab.root.find(base) != null) {
        name = uniqueDstName(tab, base, &name_buf) orelse {
            self.setStatusFmt("no free name for {s}", .{base});
            return;
        };
    }
    const dir = tab.root.path;
    var dst_buf: [4096]u8 = undefined;
    const dst = std.fmt.bufPrint(&dst_buf, "{s}/{s}", .{
        if (dir.len == 1) "" else dir, name,
    }) catch return;
    var lbl: [160]u8 = undefined;
    const label = std.fmt.bufPrint(&lbl, "new from template {s}", .{base}) catch "new from template";
    self.startDaemonJobUndo(tab.hc, "copy", source, dst, label, self.makeUndo(tab.hc.host, .delete_created, dst, source, ""), .{});
    self.setStatusFmt("creating {s} from template on {s}", .{ name, tab.hc.label() });
}
