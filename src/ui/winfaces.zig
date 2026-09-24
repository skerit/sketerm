//! Tabs and splits that open on a face -- file browser, web, editor
//! -- plus the browser face's window hooks and the shared transfer
//! service, split out of window.zig. Functions keep the owning *Window
//! receiver and are aliased back into Window.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const winmod = @import("window.zig");
const Window = winmod.Window;
const Pane = @import("pane.zig").Pane;
const file_transfers = @import("file_transfers.zig");
const webgroup = @import("webgroup.zig");
const Terminal = @import("../terminal.zig").Terminal;
const files_entry = @import("../filebrowser/entry.zig");
const logActionError = winmod.logActionError;
const showToast = winmod.showToast;
const tabPageForPane = winmod.tabPageForPane;
const paneBrowserSpec = Window.paneBrowserSpec;

/// New tab whose pane wears the file-browser face (the shell
/// session underneath stays one toolbar click away).
pub fn newBrowserTab(self: *Window) !void {
    try newBrowserTabAt(self, null);
}

/// Browser tab starting at `spec` (host-qualified allowed); null
/// = the focused pane's location.
fn newBrowserTabAt(self: *Window, spec: ?[]const u8) !void {
    try self.newBrowserTabFrom(self.focusedPane(), spec);
}

/// Browser tab starting at `spec`, else at `origin`'s host-qualified
/// location. `origin` is the pane the request came FROM (the
/// invoking pane for `sketerm files --tab`), never the pane that
/// ends up wearing the browser face.
pub fn newBrowserTabFrom(self: *Window, origin: ?*Pane, spec: ?[]const u8) !void {
    return self.newBrowserTabFromReveal(origin, spec, null);
}

pub fn newBrowserTabFromReveal(self: *Window, origin: ?*Pane, spec: ?[]const u8, reveal: ?[]const u8) !void {
    var spec_buf: [@import("browser.zig").SPEC_BUF_LEN]u8 = undefined;
    const start_spec: ?[]const u8 = if (spec) |s|
        files_entry.startLocation(&spec_buf, s)
    else if (origin) |p|
        paneBrowserSpec(p, &spec_buf)
    else
        null;
    // Take the pane the tab spawn APPENDED, exactly like
    // newBrowserSplit: focus does not reliably sit on the fresh
    // pane, and attaching to the focused one turned a PRE-EXISTING
    // pane into a browser while the new tab kept an unused shell.
    const before = self.panes.items.len;
    try self.newShellTab("Files");
    if (self.panes.items.len <= before) return error.TabSpawnFailed;
    const pane = self.panes.items[self.panes.items.len - 1];
    const bv = @import("browser.zig").BrowserView.attach(self.allocator, pane, start_spec) catch |err| {
        logActionError("new_browser_tab attach", err);
        return err;
    };
    self.installBrowserHooks(bv);
    if (reveal) |target| bv.queueReveal(target);
}

/// New tab whose pane wears the WEB face (src/ui/webface.zig): a
/// browser view served by the `sketerm-webengine` helper. The shell
/// session underneath stays one toolbar click away, exactly like
/// the file-browser and editor faces.
pub fn newWebTab(self: *Window) !void {
    try self.newWebTabAt(null);
}

/// Web tab opening `url`; null = an empty address bar. Also the
/// landing point for a page's popup request (target=_blank).
pub fn newWebTabAt(self: *Window, url: ?[]const u8) !void {
    // "Always open this site in X" applies to a fresh tab too — a
    // popup or an external link to an assigned site must land in its
    // identity, not in the default jar.
    const assigned = @import("webface.zig").containerForUrl(url, 0);
    if (assigned != 0) return self.newWebTabInContainer(assigned, url);
    // Same appended-pane rule as newBrowserTabFromReveal: focus
    // does not reliably sit on the fresh pane.
    const before = self.panes.items.len;
    try self.newShellTab("Web");
    if (self.panes.items.len <= before) return error.TabSpawnFailed;
    const pane = self.panes.items[self.panes.items.len - 1];
    _ = @import("webface.zig").WebFace.attach(self.allocator, pane, url) catch |err| {
        logActionError("new_web_tab attach", err);
        return err;
    };
}

/// Web tab created inside an identity container (`container` = 0 is
/// the default context). The container's accent colors the tab.
pub fn newWebTabInContainer(self: *Window, container: u32, url: ?[]const u8) !void {
    const webface = @import("webface.zig");
    const before = self.panes.items.len;
    try self.newShellTab("Web");
    if (self.panes.items.len <= before) return error.TabSpawnFailed;
    const pane = self.panes.items[self.panes.items.len - 1];
    _ = webface.WebFace.attachContainer(self.allocator, pane, url, container) catch |err| {
        logActionError("new_web_tab_in_container attach", err);
        return err;
    };
    // Accent the tab with the container color.
    if (webface.containerColor(container)) |rgb| {
        if (tabPageForPane(self, pane)) |page| self.setTabColor(page, rgb);
    }
}

/// Open a web tab in a fresh throwaway incognito container.
pub fn newIncognitoWebTab(self: *Window) !void {
    const webface = @import("webface.zig");
    const id = webface.createIncognito(self.allocator);
    if (id == 0) return error.ContainerCreateFailed;
    try self.newWebTabInContainer(id, null);
}

/// Web tab born on `route` (src/web/route.zig), `url` loaded in
/// that route's instance from the first request on. Unlike opening
/// a tab and then moving it, no request ever takes the direct path.
fn newWebTabRouted(self: *Window, url: ?[]const u8, route: @import("../web/route.zig").Spec) !void {
    const before = self.panes.items.len;
    try self.newShellTab("Web");
    if (self.panes.items.len <= before) return error.TabSpawnFailed;
    const pane = self.panes.items[self.panes.items.len - 1];
    _ = @import("webface.zig").WebFace.attachRouted(self.allocator, pane, url, route) catch |err| {
        logActionError("new_web_tab_routed attach", err);
        return err;
    };
}

/// `new_tor_web_tab`: a blank tab on the Tor route. A missing or
/// malformed `mux_tor_socks_endpoint` is said in a toast rather
/// than becoming a direct tab.
pub fn newTorWebTab(self: *Window) !void {
    const webface = @import("webface.zig");
    const spec = @import("../web/route.zig").Choice.tor.spec("", webface.torEndpoint()) orelse {
        showToast(self, "Tor is not configured: mux_tor_socks_endpoint must be a host:port.");
        return error.InvalidRoute;
    };
    try newWebTabRouted(self, null, spec);
}

/// Fill this window with the web tabs a `sketerm web [urls...]`
/// invocation asked for: one tab per address, or a single blank tab
/// (address entry focused) when none were given. `route` is the
/// `--route` text every tab is born on; null = the configured
/// default. Text outside the grammar was refused by the CLI parser,
/// so a null here after a non-null text can only be a Tor endpoint
/// that stopped being valid, and that is refused too.
pub fn openWebTabs(self: *Window, urls: []const []u8, route: ?[]const u8) !void {
    const webroute = @import("../web/route.zig");
    const spec: ?webroute.Spec = if (route) |r|
        webroute.Spec.parse(r, @import("webface.zig").torEndpoint()) orelse {
            showToast(self, "That --route cannot be started: check mux_tor_socks_endpoint.");
            return error.InvalidRoute;
        }
    else
        null;
    if (urls.len == 0) {
        if (spec) |s| return newWebTabRouted(self, null, s);
        return self.newWebTabAt(null);
    }
    for (urls) |url| {
        if (spec) |s| try newWebTabRouted(self, url, s) else try self.newWebTabAt(url);
    }
}

/// A repeat launch of the browser identity (`sketerm web` again):
/// another web window, the way a browser behaves.
pub fn openWebWindow(self: *Window, urls: []const []u8, route: ?[]const u8) !*Window {
    const win = self.spawnSecondaryWindow() orelse return error.WindowSpawnFailed;
    try win.openWebTabs(urls, route);
    return win;
}

/// Split the focused pane and give the new pane a web face.
pub fn newWebSplit(self: *Window, orient: c_uint) !void {
    const source = self.focusedPane() orelse return error.SplitFailed;
    try self.newWebSplitOn(source, orient);
}

/// Split a SPECIFIC pane and give the new pane a web face. Remote
/// callers (`web-open` where=split) name the pane, or resolve one
/// deterministically, rather than trusting wherever GTK focus sits
/// at the moment a socket request lands.
pub fn newWebSplitOn(self: *Window, source: *Pane, orient: c_uint) !void {
    const before = self.panes.items.len;
    try self.splitPane(source, orient);
    if (self.panes.items.len <= before) return error.SplitFailed;
    const pane = self.panes.items[self.panes.items.len - 1];
    _ = @import("webface.zig").WebFace.attach(self.allocator, pane, null) catch |err| {
        logActionError("new_web_split attach", err);
        return err;
    };
}

/// `web_discard_background`: let go of every web page that is not
/// on screen, right now. The panes keep their last frame; each
/// reloads when it is next looked at.
pub fn discardBackgroundWebTabs(self: *Window) void {
    const webface = @import("webface.zig");
    if (!webface.discardSupported()) {
        showToast(self, "The browser helper in use cannot discard pages.");
        return;
    }
    const n = webface.discardBackground();
    if (n == 0) {
        showToast(self, "No background web pages to discard.");
        return;
    }
    var buf: [96]u8 = undefined;
    const msg = std.fmt.bufPrintZ(&buf, "Discarded {d} background web page{s}.", .{
        n,
        if (n == 1) "" else "s",
    }) catch return;
    showToast(self, msg);
}

/// A palette verb that only means something on a pane wearing the
/// WEB face. A pane without one is told so, rather than left
/// wondering why the action did nothing.
pub fn webFaceAction(self: *Window, what: enum { devtools, print_pdf, fill_password, site_info, route_menu, route_direct, route_tor }) void {
    const pane = self.focusedPane() orelse return;
    const face = @import("webface.zig").WebFace.fromPane(pane) orelse {
        showToast(self, "This pane has no web page. Use New Web Tab.");
        return;
    };
    switch (what) {
        .devtools => face.openDevTools(),
        .print_pdf => face.printToPdf(),
        .fill_password => face.fillPassword(),
        .site_info => face.showSiteInfo(),
        .route_menu => face.showRouteMenu(face.route_btn),
        .route_direct => face.chooseRoute(.direct),
        .route_tor => face.chooseRoute(.tor),
    }
}

/// Split `source` and give the new pane a web face bound to an
/// EXISTING helper-side view — the inspector `devtools_show`
/// minted for the page in `source` (src/ui/webface.zig).
///
/// `splitPane`, not `splitFocused`: the reply that brings the view
/// id arrives from the socket, by which time focus may sit
/// anywhere, and splitting the wrong pane would put DevTools
/// beside a page it does not inspect.
pub fn openDevToolsSplit(self: *Window, source: *Pane, view: u32) !void {
    // The inspector view lives on the SOURCE face's helper (which
    // may be a remote one); the new face must attach to that same
    // client or its frames would never find it.
    const src_face = @import("webface.zig").WebFace.fromPane(source) orelse return error.NoWebFace;
    const before = self.panes.items.len;
    try self.splitPane(source, @intCast(c.GTK_ORIENTATION_HORIZONTAL));
    if (self.panes.items.len <= before) return error.SplitFailed;
    const pane = self.panes.items[self.panes.items.len - 1];
    _ = @import("webface.zig").WebFace.attachView(self.allocator, pane, view, src_face.cl) catch |err| {
        logActionError("web_devtools attach", err);
        return err;
    };
}

/// New tab whose pane wears the text-editor face (the shell
/// session underneath stays one toolbar click away).
pub fn newEditorTab(self: *Window) !void {
    try self.newEditorTabAt(null);
}

/// Editor tab opening `spec` (host-qualified allowed); null = an
/// empty Untitled buffer.
pub fn newEditorTabAt(self: *Window, spec: ?[]const u8) !void {
    // Same appended-pane rule as newBrowserTabFromReveal.
    const before = self.panes.items.len;
    try self.newShellTab("Editor");
    if (self.panes.items.len <= before) return error.TabSpawnFailed;
    const pane = self.panes.items[self.panes.items.len - 1];
    _ = @import("editorview.zig").EditorView.attach(self.allocator, pane, spec) catch |err| {
        logActionError("new_editor_tab attach", err);
        return err;
    };
}

/// Split the focused pane and give the new pane an editor face,
/// on the same empty Untitled buffer `new_editor_tab` starts from.
pub fn newEditorSplit(self: *Window, orient: c_uint) !void {
    // Take the pane the split APPENDED: focus may still sit on the
    // source pane, and attaching there would turn an existing pane
    // into an editor instead of the new one.
    const before = self.panes.items.len;
    try self.splitFocused(orient);
    if (self.panes.items.len <= before) return error.SplitFailed;
    const pane = self.panes.items[self.panes.items.len - 1];
    _ = @import("editorview.zig").EditorView.attach(self.allocator, pane, null) catch |err| {
        logActionError("new_editor_split attach", err);
        return err;
    };
}

/// Put an editor face on `pane` itself (the browser's "Edit in
/// Sketerm Editor"). A pane already wearing one gains a document
/// tab instead (attach handles that).
pub fn openEditorOn(self: *Window, pane: *Pane, spec: ?[]const u8) !void {
    _ = try @import("editorview.zig").EditorView.attach(self.allocator, pane, spec);
}

/// Unsaved editor tabs across every pane of this window.
pub fn editorDirtyTotal(self: *Window) usize {
    var n: usize = 0;
    for (self.panes.items) |p| {
        if (@import("editorview.zig").EditorView.fromPane(p)) |ev| n += ev.dirtyCount();
    }
    return n;
}

/// Put a browser face on `pane` itself (`sketerm files --here`):
/// the pane's shell stays alive underneath, one toolbar click away.
/// A pane that ALREADY wears a browser face gains a browser tab
/// instead -- re-attaching is a no-op that would silently drop the
/// requested location.
pub fn openBrowserHere(self: *Window, pane: *Pane, spec: ?[]const u8) !void {
    const browser_mod = @import("browser.zig");
    var spec_buf: [browser_mod.SPEC_BUF_LEN]u8 = undefined;
    const start_spec: ?[]const u8 = if (spec) |s|
        files_entry.startLocation(&spec_buf, s)
    else
        paneBrowserSpec(pane, &spec_buf);
    if (browser_mod.BrowserView.fromPane(pane)) |bv| {
        if (start_spec) |s| _ = bv.newTabSpec(s);
        return;
    }
    const bv = try browser_mod.BrowserView.attach(self.allocator, pane, start_spec);
    self.installBrowserHooks(bv);
}

/// Split the focused pane and give the new pane a browser face:
/// the way a dual-pane (source/target) layout is created.
pub fn newBrowserSplit(self: *Window, orient: c_uint) !void {
    // Outlives the block: currentSpec writes into the caller's buffer.
    var spec_buf: [@import("browser.zig").SPEC_BUF_LEN]u8 = undefined;
    const start_cwd: ?[]const u8 = blk: {
        const focused = self.focusedPane() orelse break :blk null;
        if (@import("browser.zig").BrowserView.fromPane(focused)) |bv| break :blk bv.currentSpec(&spec_buf);
        break :blk paneBrowserSpec(focused, &spec_buf);
    };
    // Take the pane the split APPENDED: focus may still sit on the
    // source pane's browser widget, and attaching there would be a
    // no-op on the pane that already has a browser.
    const before = self.panes.items.len;
    try self.splitFocused(orient);
    if (self.panes.items.len <= before) return error.SplitFailed;
    const pane = self.panes.items[self.panes.items.len - 1];
    const bv = @import("browser.zig").BrowserView.attach(self.allocator, pane, start_cwd) catch |err| {
        logActionError("new_browser_split attach", err);
        return err;
    };
    self.installBrowserHooks(bv);
}

/// The process-shared durable transfer service, acquired on first
/// use. Null only when the ledger directory is unusable.
pub fn transferService(self: *Window) ?*file_transfers.Service {
    if (self.file_transfer_service == null) {
        self.file_transfer_service = file_transfers.acquire(
            self.allocator,
            @ptrCast(self),
            &browserTransferNotify,
        ) catch null;
    }
    return self.file_transfer_service;
}

/// Give a browser face its window-level abilities: durable
/// terminal tabs on any host, and app-forwarded remote opens.
pub fn installBrowserHooks(self: *Window, bv: *@import("browser.zig").BrowserView) void {
    bv.transfer_service = self.transferService();
    // Client-mediated transfers need a browser face with both host
    // connections; the service hands over any whose owner is gone.
    if (self.file_transfer_service) |service|
        service.addMediatedDriver(
            @ptrCast(bv),
            &@import("browser/jobs.zig").adoptMediated,
            &@import("browser/ops.zig").adoptPasteBatch,
            &@import("browser/jobs.zig").refreshJobsPanel,
        );
    bv.hooks_ctx = @ptrCast(self);
    bv.on_peer = &browserPeerCb;
    bv.on_host_term = &browserHostTermCb;
    bv.on_host_open = &browserHostOpenCb;
    bv.on_host_exec = &browserHostExecCb;
}

/// The other browser face in `pane`'s tab, from the pane-tree
/// MODEL (correct while a pane is zoomed). Exactly two browser
/// faces make a dual-pane pair; with more, the first other one
/// wins so the destination stays deterministic.
fn browserPeerCb(ctx: *anyopaque, pane: *Pane) ?*@import("browser.zig").BrowserView {
    const self: *Window = @ptrCast(@alignCast(ctx));
    const page = tabPageForPane(self, pane) orelse return null;
    const tree = Window.tabTreeOf(page) orelse return null;
    var leaves: std.ArrayList(*Pane) = .empty;
    defer leaves.deinit(self.allocator);
    tree.appendLeaves(self.allocator, &leaves) catch return null;
    for (leaves.items) |leaf| {
        if (leaf == pane) continue;
        if (@import("browser.zig").BrowserView.fromPane(leaf)) |bv| return bv;
    }
    return null;
}

fn browserTransferNotify(ctx: *anyopaque, text: []const u8) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    showToast(self, text);
}

fn browserHostTermCb(ctx: *anyopaque, host: []const u8, path: []const u8) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    const h: ?[]const u8 = if (host.len > 0) host else null;
    self.newDurableSessionAt(h, path) catch |err|
        logActionError("browser terminal-here", err);
}

fn browserHostExecCb(ctx: *anyopaque, host: []const u8, cmdline: []const u8) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    const h: ?[]const u8 = if (host.len > 0) host else null;
    const argv = [_][]const u8{ "/bin/sh", "-c", cmdline };
    self.launchRemoteAppSession(h, &argv, false) catch |err|
        logActionError("browser action-exec", err);
}

/// Open a path with the HOST's desktop opener. Which opener that is
/// can only be decided on the host: `host` may be a Mac (`open`) or
/// a Linux box (`xdg-open`), and so may this machine, so the choice
/// cannot be made from our own `builtin.os.tag`. Hardcoding
/// `xdg-open` made this menu item do nothing at all, silently,
/// against every macOS host including localhost.
///
/// The last branch exists so a host with NEITHER opener says so on
/// stderr and exits non-zero, rather than looking like a success.
const host_open_sh =
    \\if command -v xdg-open >/dev/null 2>&1; then exec xdg-open "$1"; fi
    \\if command -v open >/dev/null 2>&1; then exec open "$1"; fi
    \\echo "sketerm: no xdg-open or open on this host" >&2
    \\exit 127
;

fn browserHostOpenCb(ctx: *anyopaque, host: []const u8, path: []const u8) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    const h: ?[]const u8 = if (host.len > 0) host else null;
    const argv = [_][]const u8{ "/bin/sh", "-c", host_open_sh, "sketerm-open", path };
    self.launchRemoteAppSession(h, &argv, false) catch |err|
        logActionError("browser open-on-host", err);
}
