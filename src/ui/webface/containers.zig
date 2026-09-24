//! Containers (per-tab identity contexts), the browser.tabs table
//! published to each helper, filter-list subscription config and the
//! daemon-stored container list, split out of `webface.zig`. Like the
//! `Client` singleton, the registry is process-wide.

const std = @import("std");
const Window = @import("../window.zig").Window;
const c = @import("../../c.zig").c;
const proto = @import("../../web/protocol.zig");
const webroute = @import("../../web/route.zig");
const webstore = @import("../webstore.zig");
const host_mod = @import("../webface.zig");
const Client = host_mod.Client;
const WebFace = host_mod.WebFace;
const client = host_mod.client;
const clientForRoute = host_mod.clientForRoute;
const routeForContainer = host_mod.routeForContainer;
const setRouteDefaults = host_mod.setRouteDefaults;
const torEndpoint = host_mod.torEndpoint;

// ---------------------------------------------------------------------
// Containers — per-tab identity contexts (private cookie jar / cache,
// optional remote egress). The registry is process-wide, like the
// Client singleton; a container id is minted here, published to the
// helper as a `context_create`, and named by a face's `container` field.
// ---------------------------------------------------------------------

/// A small, visually distinct accent palette; the last entry is the
/// incognito preset's slate.
pub const container_palette = [_][3]u8{
    .{ 0x3b, 0x82, 0xf6 }, // blue
    .{ 0x22, 0xc5, 0x5e }, // green
    .{ 0xf5, 0x9e, 0x0b }, // amber
    .{ 0xef, 0x44, 0x44 }, // red
    .{ 0xa8, 0x55, 0xf7 }, // purple
    .{ 0x14, 0xb8, 0xa6 }, // teal
    .{ 0xec, 0x48, 0x99 }, // pink
    .{ 0x64, 0x74, 0x8b }, // slate (incognito)
};

pub const Container = struct {
    id: u32,
    /// Display name. Freely renameable, and NOT what the engine keys
    /// its cookie jar on — see `jar`.
    name: []u8,
    /// The name published to the helper as `context_create.name`, and
    /// thus half of the engine's on-disk jar path
    /// (`{profile}/{jar}-{id}`, an immediate child of the profile
    /// directory; `cefhost.sanitizeContextName`).
    /// Fixed at creation so a RENAME keeps the cookies: deriving the
    /// path from the display name would silently hand a renamed
    /// container a fresh, empty jar.
    jar: []u8,
    color: [3]u8,
    ephemeral: bool,
    /// The DEFAULT route of tabs opened in this container (a tab may
    /// override it through `WebFace.setRoute`). A route is realized as
    /// a whole helper instance (`clientForRoute`), never as a proxy on
    /// this container's context: stock CEF gives a profile one proxy,
    /// and a per-context proxy would be lost the moment the tab moved
    /// to a Tor instance. The Tor endpoint is not stored per container;
    /// `route()` resolves it from config at use.
    route_kind: webroute.Kind,
    /// Owned host for `.mux` / `.remote_browser`; "" otherwise.
    route_host: []u8,

    pub fn route(self: *const Container) webroute.Spec {
        return switch (self.route_kind) {
            .direct => .{},
            .tor => .{ .kind = .tor, .endpoint = torEndpoint() },
            .mux, .remote_browser => .{ .kind = self.route_kind, .host = self.route_host },
        };
    }
};

pub var g_containers: std.ArrayList(Container) = .empty;
pub var g_next_container_id: u32 = 1;
/// Ephemeral (incognito) ids are the wire's ephemeral context partition,
/// above every id the daemon store will ever mint — see
/// `createContainerAt`.
pub const EPHEMERAL_CONTAINER_BASE: u32 = proto.EPHEMERAL_CTX_BASE;
pub var g_next_ephemeral_id: u32 = EPHEMERAL_CONTAINER_BASE;

pub fn containers() []Container {
    return g_containers.items;
}

pub fn findContainer(id: u32) ?*Container {
    for (g_containers.items) |*ctn| {
        if (ctn.id == id) return ctn;
    }
    return null;
}

/// Accent color of a container, or null for the default context.
pub fn containerColor(id: u32) ?[3]u8 {
    if (id == 0) return null;
    if (findContainer(id)) |ctn| return ctn.color;
    return null;
}

/// Create a session-local container whose tabs default to `route`.
/// Returns the new id (0 on allocation failure or an invalid route).
pub fn createContainer(
    gpa: std.mem.Allocator,
    name: []const u8,
    ephemeral: bool,
    route: webroute.Spec,
) u32 {
    return createContainerAt(gpa, .{
        .name = name,
        .ephemeral = ephemeral,
        .route = route,
    });
}

/// Everything a container can be created with. `id` 0 mints a fresh id;
/// a non-zero one ADOPTS a persisted container, which is how a stored
/// identity keeps the engine jar it already has on disk.
pub const ContainerSpec = struct {
    id: u32 = 0,
    name: []const u8,
    jar: []const u8 = "",
    color: ?[3]u8 = null,
    ephemeral: bool = false,
    /// Default route; only its kind and host are kept (a Tor endpoint
    /// is config, not identity).
    route: webroute.Spec = .{},
};

pub fn createContainerAt(gpa: std.mem.Allocator, spec: ContainerSpec) u32 {
    // A route that cannot be realized must not become a container that
    // LOOKS routed: refuse it here, where the caller can say so.
    if (!spec.route.valid()) return 0;
    // Ephemeral containers are minted here and never stored, so their
    // ids come from a DISJOINT high range: the daemon store counts up
    // from 1, and an incognito tab opened before the stored registry
    // arrived would otherwise be able to claim an id a real container
    // already owns on disk — two identities, one cookie jar. The range
    // is the helper's own ephemeral window: an id past it makes the
    // helper drop this GUI's whole connection.
    const id = if (spec.id != 0)
        spec.id
    else if (spec.ephemeral)
        proto.mintEphemeralCtx(&g_next_ephemeral_id) orelse return 0
    else
        g_next_container_id;
    if (findContainer(id) != null) return 0;
    const color = spec.color orelse if (spec.ephemeral)
        container_palette[container_palette.len - 1]
    else
        container_palette[(g_containers.items.len) % (container_palette.len - 1)];
    const name = spec.name;
    const ephemeral = spec.ephemeral;

    const name_owned = gpa.dupe(u8, name) catch return 0;
    const jar_owned = gpa.dupe(u8, if (spec.jar.len != 0) spec.jar else name) catch {
        gpa.free(name_owned);
        return 0;
    };
    const host_owned = gpa.dupe(u8, spec.route.host) catch {
        gpa.free(name_owned);
        gpa.free(jar_owned);
        return 0;
    };

    g_containers.append(gpa, .{
        .id = id,
        .name = name_owned,
        .jar = jar_owned,
        .color = color,
        .ephemeral = ephemeral,
        .route_kind = spec.route.kind,
        .route_host = host_owned,
    }) catch {
        gpa.free(name_owned);
        gpa.free(jar_owned);
        gpa.free(host_owned);
        return 0;
    };
    if (!ephemeral and id >= g_next_container_id) g_next_container_id = id + 1;
    // Publish to every live helper at once; a helper that starts later
    // gets the whole set replayed by `publishContexts` on connect.
    publishOne(client(), &g_containers.items[g_containers.items.len - 1]);
    for (host_mod.g_aux_clients.items) |cl| publishOne(cl, &g_containers.items[g_containers.items.len - 1]);
    return id;
}

/// Rename / recolour in place. The jar key is untouched, so the
/// container keeps every cookie it had.
pub fn renameContainer(gpa: std.mem.Allocator, id: u32, name: []const u8) bool {
    const ctn = findContainer(id) orelse return false;
    const dup = gpa.dupe(u8, name) catch return false;
    gpa.free(ctn.name);
    ctn.name = dup;
    return true;
}

pub fn recolorContainer(id: u32, rgb: [3]u8) bool {
    const ctn = findContainer(id) orelse return false;
    ctn.color = rgb;
    return true;
}

/// Forget a container: tell every helper to drop the request context
/// and release our own record. Views already open in it keep their
/// engine-side context alive (CEF holds its own reference), so an open
/// tab does not lose its jar mid-session — the id simply stops
/// resolving for anything new.
pub fn destroyContainer(gpa: std.mem.Allocator, id: u32) bool {
    for (g_containers.items, 0..) |*ctn, i| {
        if (ctn.id != id) continue;
        if (client().state == .ready) client().post(proto.ContextDestroy{ .id = id });
        for (host_mod.g_aux_clients.items) |cl| {
            if (cl.state == .ready) cl.post(proto.ContextDestroy{ .id = id });
        }
        const dead = g_containers.orderedRemove(i);
        gpa.free(dead.name);
        gpa.free(dead.jar);
        gpa.free(dead.route_host);
        // Sweep the per-site rules too, exactly as the daemon store
        // does. Leaving them behind kept routing new tabs for those
        // hosts into a destroyed identity: the helper silently falls
        // back to the shared jar, the tab loses its accent colour, and
        // the dead id gets written into the saved layout.
        var k: usize = 0;
        while (k < g_container_sites.items.len) {
            if (g_container_sites.items[k].container == id) {
                gpa.free(g_container_sites.orderedRemove(k).host);
            } else k += 1;
        }
        return true;
    }
    return false;
}

/// One-shot incognito preset: a throwaway ephemeral container.
pub fn createIncognito(gpa: std.mem.Allocator) u32 {
    return createContainer(gpa, "Incognito", true, .{});
}

pub fn publishOne(cl: *Client, ctn: *const Container) void {
    if (cl.state != .ready) return;
    cl.post(proto.ContextCreate{
        .id = ctn.id,
        .ephemeral = if (ctn.ephemeral) 1 else 0,
        // The JAR key, never the display name: this string is half the
        // engine's on-disk cache path, so it must not move when the
        // user renames the container.
        .name = ctn.jar,
        // Never a per-context proxy: the ROUTE is the helper instance
        // the view lives in (`clientForRoute`), whose `--proxy` covers
        // every context it mints. A context proxy here would follow the
        // container into a Tor instance and re-route it out of Tor.
        .proxy = "",
    });
}

/// Re-publish every container to a (possibly fresh) helper, BEFORE its
/// faces re-create their views.
pub fn publishContexts(cl: *Client) void {
    for (g_containers.items) |*ctn| publishOne(cl, ctn);
}

// ── browser.tabs: the client half of `webext_tabs` ──────────────
//
// The helper advertises `webext-tabs` and decodes 0xB6, but until this
// existed the ONLY producer in the tree was the smoke rig — so stage 35b
// was green while the shipped GUI never sent a tab list at all. Every
// dispatched request then carried `tabId = -1`, which MV2 defines as
// "not associated with a tab", and uBO reads exactly that to take its
// behind-the-scene path: it CANCELS the top-level navigation of every
// page. That is the regression the tab table was built to fix, hidden
// by a rig that posted the frame itself.

/// One tab as `webext_tabs` spells it. Field names ARE the JSON keys
/// (`cefhost.webextTabs` reads them verbatim), so they are camelCase
/// here on purpose; stringifying a struct is also what keeps a url or
/// title containing a quote from breaking the payload.
pub const TabJson = struct {
    id: u32,
    view: u32,
    windowId: u32,
    index: u32,
    active: bool,
    focusedWindow: bool,
    url: []const u8,
    title: []const u8,
    loading: bool,
};

pub fn windowFocused(win: *Window) bool {
    return c.gtk_window_is_active(@ptrCast(win.app_window)) != 0;
}

/// Post this client's whole tab list. Replace-all by design: the helper
/// diffs two consecutive tables into MV2's onCreated/onUpdated/
/// onRemoved/onActivated, so nothing can desynchronise the way an
/// incremental protocol would.
pub fn publishTabs(cl: *Client) void {
    if (!cl.has(.webext_tabs) or cl.state != .ready) return;
    var rows: std.ArrayList(TabJson) = .empty;
    defer rows.deinit(cl.gpa);
    for (cl.faces.items) |f| {
        // A face whose view has not been minted yet has nothing the
        // helper could key on, and a torn-down one must not be listed.
        if (f.view == 0 or f.widgets_dead) continue;
        const win = f.ownerWindow() orelse continue;
        var index: u32 = 0;
        for (rows.items) |row| if (row.windowId == win.id) {
            index += 1;
        };
        const pane = f.pane orelse continue;
        const active_pane = win.focusedPane() orelse win.selectedTabPane();
        const active = active_pane == pane and pane.webFaceVisible() and f.isActivePage();
        rows.append(cl.gpa, .{
            // The view id is process-wide unique and stable for the
            // face's whole life, which is exactly what a tab id has to
            // be, so it serves as both.
            .id = f.view,
            .view = f.view,
            .windowId = win.id,
            .index = index,
            .active = active,
            .focusedWindow = windowFocused(win),
            .url = if (f.url) |u| u else "",
            .title = if (f.title) |t| t else "",
            .loading = f.loading,
        }) catch return;
    }
    var aw: std.Io.Writer.Allocating = .init(cl.gpa);
    defer aw.deinit();
    std.json.Stringify.value(rows.items, .{}, &aw.writer) catch return;
    cl.post(proto.WebextTabs{ .tabs_json = aw.written() });
}

// ── filter-list subscriptions ───────────────────────────────────
//
// The GUI owns the CONFIG; the helper owns the fetching, because it is
// the only process here with an HTTPS stack. Copies are ours: a Config
// arena is per-window and freed under `applyConfigChange`.

pub var g_sub_urls: std.ArrayList([]u8) = .empty;
pub var g_sub_hours: u32 = 24;
pub var g_sub_gpa: ?std.mem.Allocator = null;

/// Publish the configured subscription set. REPLACE-ALL, so this is
/// also how "I removed my last subscription" reaches the helper and
/// gets the cache files swept.
pub fn setFilterSubscriptions(gpa: std.mem.Allocator, urls: []const []const u8, hours: u32) void {
    var next: std.ArrayList([]u8) = .empty;
    var adopted = false;
    defer if (!adopted) {
        for (next.items) |u| gpa.free(u);
        next.deinit(gpa);
    };
    for (urls) |u| {
        const d = gpa.dupe(u8, u) catch return;
        next.append(gpa, d) catch {
            gpa.free(d);
            return;
        };
    }
    const old_gpa = g_sub_gpa orelse gpa;
    for (g_sub_urls.items) |u| old_gpa.free(u);
    g_sub_urls.deinit(old_gpa);
    g_sub_urls = next;
    adopted = true;
    g_sub_gpa = gpa;
    g_sub_hours = hours;
    publishFilterSubs(&host_mod.g_client);
    for (host_mod.g_aux_clients.items) |cl| publishFilterSubs(cl);
}

pub fn publishFilterSubs(cl: *Client) void {
    if (!cl.has(.filter_subscribe) or cl.state != .ready) return;
    var view: std.ArrayList([]const u8) = .empty;
    defer view.deinit(cl.gpa);
    for (g_sub_urls.items) |u| view.append(cl.gpa, u) catch return;
    cl.post(proto.InterceptSubscribe{ .update_hours = g_sub_hours, .urls = view.items });
}

/// The tab set changed somewhere. Coalesced onto an idle so a burst of
/// per-face updates (a navigation touches url, title and loading) costs
/// one frame rather than three.
pub var g_tabs_dirty = false;

pub fn tabsChanged() void {
    if (g_tabs_dirty) return;
    g_tabs_dirty = true;
    // No user data, so nothing can dangle: the callback reads only
    // module-level state that outlives every face.
    _ = c.g_idle_add(@ptrCast(&flushTabs), null);
}

pub fn syncActionPresentation(cl: *Client) void {
    for (cl.faces.items) |face| face.syncNativeActionPresentation();
}

pub fn flushTabs(_: ?*anyopaque) callconv(.c) c.gboolean {
    g_tabs_dirty = false;
    syncActionPresentation(&host_mod.g_client);
    for (host_mod.g_aux_clients.items) |cl| syncActionPresentation(cl);
    publishTabs(&host_mod.g_client);
    for (host_mod.g_aux_clients.items) |cl| publishTabs(cl);
    return 0;
}

// ── stored containers (the daemon web store) ────────────────────

pub const SiteRule = struct { host: []u8, container: u32 };
pub var g_container_sites: std.ArrayList(SiteRule) = .empty;
pub var g_containers_loaded: bool = false;
pub var g_containers_loading: bool = false;
/// A container list actually landed. See `loadContainers` for why this
/// is not the same bit as `g_containers_loaded`.
pub var g_containers_fetched: bool = false;
pub var g_containers_gpa: ?std.mem.Allocator = null;

/// Host of an http(s) url, or null when there is nothing to key a rule
/// on (a blank tab, a data: url, a search term the omnibox has not
/// resolved yet).
/// Is the keyboard focus inside `w`? For a GtkEntry the focus widget
/// is its inner GtkText, so `gtk_widget_has_focus` on the entry itself
/// is ALWAYS false — the check that silently kept the omnibox from
/// ever showing. FOCUS_WITHIN is the containment answer.
pub fn focusWithin(w: *c.GtkWidget) bool {
    return (c.gtk_widget_get_state_flags(w) & c.GTK_STATE_FLAG_FOCUS_WITHIN) != 0;
}

pub fn hostOfUrl(url: []const u8) ?[]const u8 {
    const sep = "://";
    const i = std.mem.indexOf(u8, url, sep) orelse return null;
    var rest = url[i + sep.len ..];
    if (std.mem.indexOfAny(u8, rest, "/?#")) |end| rest = rest[0..end];
    // Strip userinfo and port; neither is part of the rule key.
    if (std.mem.lastIndexOfScalar(u8, rest, '@')) |at| rest = rest[at + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        // Leave a bare IPv6 literal alone.
        if (std.mem.indexOfScalar(u8, rest, ']') == null) rest = rest[0..colon];
    }
    return if (rest.len == 0) null else rest;
}

test "a helper socket is adopted only from this route and another process" {
    const t = std.testing;
    // Direct route: `web-<pid>.sock`, someone else's pid.
    try t.expectEqual(@as(?i32, 1234), Client.helperSocketOfRoute("web-1234.sock", null, 99));
    try t.expect(Client.helperSocketOfRoute("web-1234.sock", null, 1234) == null); // our own
    // A routed instance's socket is a DIFFERENT profile: never direct's.
    try t.expect(Client.helperSocketOfRoute("web-1234-tor.sock", null, 99) == null);
    try t.expectEqual(@as(?i32, 1234), Client.helperSocketOfRoute("web-1234-tor.sock", "tor", 99));
    try t.expect(Client.helperSocketOfRoute("web-1234-tor.sock", "via-box", 99) == null);
    try t.expect(Client.helperSocketOfRoute("web-1234.sock", "tor", 99) == null);
    // Neighbours in the same directory that are not helper sockets.
    try t.expect(Client.helperSocketOfRoute("mux.sock", null, 99) == null);
    try t.expect(Client.helperSocketOfRoute("1234.sock", null, 99) == null);
    try t.expect(Client.helperSocketOfRoute("web-.sock", null, 99) == null);
    try t.expect(Client.helperSocketOfRoute("web-12ab.sock", null, 99) == null);
    try t.expect(Client.helperSocketOfRoute("web-1234.sock.tmp", null, 99) == null);
}

test "hostOfUrl keys a site rule on the host alone" {
    const t = std.testing;
    try t.expectEqualStrings("example.com", hostOfUrl("https://example.com/a/b?c#d").?);
    try t.expectEqualStrings("example.com", hostOfUrl("http://example.com").?);
    // Port and userinfo are not part of the identity of a site.
    try t.expectEqualStrings("example.com", hostOfUrl("https://example.com:8443/x").?);
    try t.expectEqualStrings("example.com", hostOfUrl("https://user@example.com/x").?);
    try t.expectEqualStrings("127.0.0.1", hostOfUrl("http://127.0.0.1:9/?set").?);
    // Nothing to key a rule on: no scheme, or no host at all.
    try t.expect(hostOfUrl("") == null);
    try t.expect(hostOfUrl("about:blank") == null);
    try t.expect(hostOfUrl("data:text/html,<p>x") == null);
    try t.expect(hostOfUrl("https://") == null);
}

test "containerForUrl falls back when no rule names the host" {
    const t = std.testing;
    // With an empty rule table every url keeps the inherited container,
    // so a link followed inside a container stays in it.
    try t.expectEqual(@as(u32, 4), containerForUrl("https://example.com/", 4));
    try t.expectEqual(@as(u32, 0), containerForUrl(null, 0));
    try t.expectEqual(@as(u32, 9), containerForUrl("about:blank", 9));
}

test "a container with an invalid route is refused, not registered direct" {
    const t = std.testing;
    const before = g_containers.items.len;
    // A host-kind route with no host, and a Tor route with no endpoint.
    try t.expectEqual(@as(u32, 0), createContainerAt(t.allocator, .{
        .id = 0x7fff_ff00,
        .name = "unreachable",
        .ephemeral = true,
        .route = .{ .kind = .mux },
    }));
    try t.expectEqual(@as(u32, 0), createContainerAt(t.allocator, .{
        .id = 0x7fff_ff01,
        .name = "notor",
        .ephemeral = true,
        .route = .{ .kind = .tor },
    }));
    try t.expectEqual(before, g_containers.items.len);
}

test "a container's route is the default for its tabs and resolves Tor from config" {
    const t = std.testing;
    // A Container VALUE, not a registry entry: the registry is a global
    // ArrayList that a test could only grow, never free.
    var host_buf = [_]u8{ 'g', 'a', 't', 'e' };
    const onion = Container{
        .id = 0x7fff_ff02,
        .name = &.{},
        .jar = &.{},
        .color = .{ 0, 0, 0 },
        .ephemeral = true,
        .route_kind = .tor,
        .route_host = &.{},
    };
    setRouteDefaults("direct", "127.0.0.1:9050");
    try t.expectEqual(webroute.Kind.tor, onion.route().kind);
    try t.expectEqualStrings("127.0.0.1:9050", onion.route().endpoint);
    // The endpoint follows config, not the container.
    setRouteDefaults("direct", "127.0.0.1:9150");
    try t.expectEqualStrings("127.0.0.1:9150", onion.route().endpoint);
    const via = Container{
        .id = 0x7fff_ff03,
        .name = &.{},
        .jar = &.{},
        .color = .{ 0, 0, 0 },
        .ephemeral = true,
        .route_kind = .mux,
        .route_host = &host_buf,
    };
    try t.expectEqualStrings("gate", via.route().host);
    // A routeless container (or none) falls back to `web_route`.
    setRouteDefaults("via:gate", "127.0.0.1:9050");
    try t.expectEqual(webroute.Kind.mux, routeForContainer(0).kind);
    try t.expectEqualStrings("gate", routeForContainer(0).host);
    setRouteDefaults("direct", "127.0.0.1:9050");
    try t.expect(routeForContainer(0).isDirect());
}

/// Container a url should open in. An explicit per-site rule BEATS the
/// container that would otherwise be inherited — that is what "always
/// open this site in Work" means, including when the link was followed
/// from somewhere else.
///
/// This decides where a NEW page or tab is created. A navigation inside
/// a page that is already open is deliberately not re-homed: a view's
/// request context is fixed at `view_create`, so moving it would mean
/// tearing the page down and reloading it under the user, losing form
/// state and history. Firefox re-opens in a new tab for the same
/// reason; doing that automatically on every in-page navigation is a
/// bigger behavioural claim than this makes.
pub fn containerForUrl(url: ?[]const u8, fallback: u32) u32 {
    const u = url orelse return fallback;
    const host = hostOfUrl(u) orelse return fallback;
    const assigned = containerForHost(host);
    return if (assigned != 0) assigned else fallback;
}

/// Container a per-site rule assigns `host` to, or 0 for none.
pub fn containerForHost(host: []const u8) u32 {
    for (g_container_sites.items) |rule| {
        if (std.ascii.eqlIgnoreCase(rule.host, host)) return rule.container;
    }
    return 0;
}

/// Record "always open `host` in `id`" (0 clears), locally and in the
/// daemon store. The local cache is updated first so the very next
/// navigation obeys the rule without waiting for the round trip.
pub fn setSiteContainer(gpa: std.mem.Allocator, host: []const u8, id: u32) void {
    for (g_container_sites.items, 0..) |*rule, i| {
        if (!std.ascii.eqlIgnoreCase(rule.host, host)) continue;
        if (id == 0) {
            gpa.free(g_container_sites.orderedRemove(i).host);
        } else rule.container = id;
        _ = webstore.containerSiteSet(gpa, host, id, null, &onStoreAck);
        return;
    }
    if (id != 0) {
        const owned = gpa.dupe(u8, host) catch return;
        g_container_sites.append(gpa, .{ .host = owned, .container = id }) catch {
            gpa.free(owned);
            return;
        };
    }
    _ = webstore.containerSiteSet(gpa, host, id, null, &onStoreAck);
}

/// Fire-and-forget store writes still need a callback slot; nothing is
/// resolved through it, so there is nothing to fence.
pub fn onStoreAck(_: ?*anyopaque, _: bool, _: []const u8) void {}

/// Pull the stored registry in. Idempotent, and safe to call before any
/// helper exists.
///
/// The reply callback carries a NULL context on purpose: everything it
/// touches is module-global state that lives as long as the process
/// (the same immortality that fences `clientForHost`), so there is no
/// owner whose teardown a `webstore.cancelFor` would have to match.
pub fn loadContainers(gpa: std.mem.Allocator) void {
    // `g_containers_loaded` is the GATE (views waiting on the registry
    // are released and it never closes again); `g_containers_fetched`
    // is whether we actually have the list. They are separate because a
    // FAILED fetch must still open the gate — a container-bound view
    // would otherwise wait forever — while staying retryable. Collapsing
    // them latched an empty registry for the whole session.
    if (g_containers_loading or g_containers_fetched) return;
    g_containers_gpa = gpa;
    g_containers_loading = true;
    if (!webstore.containerList(gpa, null, &onContainerList)) {
        // No daemon-side store on this host: containers degrade to
        // session-local rather than wedging every container-bound view.
        g_containers_loading = false;
        markContainersReady(gpa);
    }
}

pub fn onContainerList(_: ?*anyopaque, ok: bool, payload: []const u8) void {
    const gpa = g_containers_gpa orelse return;
    g_containers_loading = false;
    if (!ok) return markContainersReady(gpa);
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const rep = webstore.parseContainers(arena.allocator(), payload);
    g_containers_fetched = true;
    for (rep.containers) |stored| {
        if (stored.id == 0 or stored.name.len == 0) continue;
        // Adopt the STORED id: it is the engine's jar path component.
        // A stored route the grammar refuses (a Tor endpoint that is no
        // longer valid) keeps the container OUT of the registry rather
        // than adopting it as direct under a routed name.
        const route = webroute.Spec.parse(stored.route, torEndpoint()) orelse {
            std.debug.print("sketerm: container '{s}' has an unusable route '{s}'; not loaded\n", .{ stored.name, stored.route });
            continue;
        };
        _ = createContainerAt(gpa, .{
            .id = stored.id,
            .name = stored.name,
            .jar = stored.jar,
            .color = stored.color,
            .route = route,
        });
    }
    for (rep.sites) |rule| {
        if (rule.host.len == 0 or rule.container == 0) continue;
        const owned = gpa.dupe(u8, rule.host) catch continue;
        g_container_sites.append(gpa, .{ .host = owned, .container = rule.container }) catch
            gpa.free(owned);
    }
    markContainersReady(gpa);
}

/// Open the gate: publish every container to every live helper, then
/// let the faces that were waiting on it mint their views.
pub fn markContainersReady(gpa: std.mem.Allocator) void {
    if (g_containers_loaded) return;
    g_containers_loaded = true;
    publishContexts(client());
    for (host_mod.g_aux_clients.items) |cl| publishContexts(cl);
    rehomeContainerFaces(gpa);
    for (client().faces.items) |f| f.ensureView();
    for (host_mod.g_aux_clients.items) |cl| {
        for (cl.faces.items) |f| f.ensureView();
    }
}

/// Move container-bound faces onto the instance their container's
/// route names, now that the registry says which one that is.
///
/// `attachOpts` picks a face's route at ATTACH time via
/// `routeForContainer`, and a `--restore` runs the whole layout build
/// synchronously BEFORE the stored registry lands — so `findContainer`
/// returned null and every container-bound face took the default
/// route. A container routed elsewhere then browsed directly while the
/// tab wore the container's name and colour: wrong egress, no error
/// anywhere. Faces that already adopted a live view, and faces whose
/// route the user chose explicitly, are left alone.
pub fn rehomeContainerFaces(gpa: std.mem.Allocator) void {
    // Collect first: re-homing mutates the clients' face lists.
    var moving: std.ArrayList(*WebFace) = .empty;
    defer moving.deinit(gpa);
    for (host_mod.g_client.faces.items) |f| {
        if (f.container == 0 or f.attached or f.widgets_dead or f.view_live or f.route_explicit) continue;
        if (findContainer(f.container) == null) continue;
        moving.append(gpa, f) catch return;
    }
    for (moving.items) |f| {
        // Resolved here rather than in the scan above: this is what
        // CREATES the route's client, and doing that while walking
        // `g_client.faces` would be a side effect mid-iteration.
        const spec = routeForContainer(f.container);
        const want = clientForRoute(gpa, spec) orelse continue;
        if (!f.storeRoute(spec)) continue;
        if (want == f.cl) continue;
        f.cl.unregister(f);
        f.cl = want;
        want.ensure(gpa);
        want.register(f);
    }
}

/// Result of a stored-container create: the new id, or 0 on failure.
pub const ContainerCreated = *const fn (ctx: ?*anyopaque, id: u32) void;

pub const PendingCreate = struct {
    allocator: std.mem.Allocator,
    ctx: ?*anyopaque,
    cb: ?ContainerCreated,
    name: []u8,
    /// `web/route.zig` text, as the store keeps it.
    route: []u8,
    color: [3]u8,

    pub fn free(self: *PendingCreate) void {
        self.allocator.free(self.name);
        self.allocator.free(self.route);
        self.allocator.destroy(self);
    }
};

/// Live `PendingCreate`s, so a caller that goes away before its reply
/// lands can be severed.
///
/// The webstore request is registered under the PendingCreate, NOT under
/// the caller's ctx, so `webstore.cancelFor(caller)` cannot see it — the
/// container manager closed while a create was in flight and the reply
/// (or `failPending` on a dropped store connection) then called back
/// into a freed Manager and drove GTK with its finalized widgets. The
/// pending itself must STAY registered, because webstore still owns the
/// reply and `onContainerAdded` is what frees it; only the callback is
/// dropped.
pub var pending_creates: std.ArrayList(*PendingCreate) = .empty;

/// Sever the create callback for a caller that is being torn down.
/// Idempotent, and safe to call for a ctx that has nothing pending.
pub fn cancelStoredCreateFor(ctx: ?*anyopaque) void {
    for (pending_creates.items) |p| {
        if (p.ctx != ctx) continue;
        p.cb = null;
        p.ctx = null;
    }
}

/// Drop `p` from the live list. Returns whether it was actually there,
/// which is how a caller learns the reply has NOT already consumed it.
pub fn forgetPendingCreate(p: *PendingCreate) bool {
    for (pending_creates.items, 0..) |it, i| {
        if (it == p) {
            _ = pending_creates.swapRemove(i);
            return true;
        }
    }
    return false;
}

/// Create a PERSISTENT container.
///
/// The id is minted by the daemon store rather than here, because it is
/// half the engine's on-disk jar path: a per-process counter would hand
/// the same identity a different jar on every launch. The container
/// therefore only exists once the reply lands, which is why this is
/// asynchronous where `createContainer` is not.
///
/// `route` is `web/route.zig` text (`direct` | `tor` | `via:<host>` |
/// `on:<host>`); an unparseable one is refused outright.
pub fn createStoredContainer(
    gpa: std.mem.Allocator,
    name: []const u8,
    color: [3]u8,
    route: []const u8,
    ctx: ?*anyopaque,
    cb: ?ContainerCreated,
) bool {
    if (name.len == 0) return false;
    // The store validates the shape too; refusing here keeps a bad
    // spelling from costing a round trip and a dangling pending.
    if (route.len != 0 and !webroute.Spec.validText(route)) return false;
    const p = gpa.create(PendingCreate) catch return false;
    p.* = .{
        .allocator = gpa,
        .ctx = ctx,
        .cb = cb,
        .color = color,
        .name = gpa.dupe(u8, name) catch {
            gpa.destroy(p);
            return false;
        },
        .route = gpa.dupe(u8, route) catch {
            gpa.free(p.name);
            gpa.destroy(p);
            return false;
        },
    };
    // Registered BEFORE the request, so a reply can never arrive for a
    // pending the cancel list does not know about.
    pending_creates.append(gpa, p) catch {
        p.free();
        return false;
    };
    // The jar key starts equal to the name and never moves again.
    if (!webstore.containerAdd(gpa, name, name, color, route, @ptrCast(p), &onContainerAdded)) {
        // A false return ALSO covers "the store connection died inside
        // the send", where `failPending` already ran `onContainerAdded`
        // — which forgot and freed `p`. Freeing again here was a double
        // free of three slices plus the struct. Whether the entry is
        // still listed is the one fact both paths agree on.
        if (forgetPendingCreate(p)) p.free();
        return false;
    }
    return true;
}

pub fn onContainerAdded(user: ?*anyopaque, ok: bool, payload: []const u8) void {
    const p: *PendingCreate = @ptrCast(@alignCast(user orelse return));
    _ = forgetPendingCreate(p);
    defer p.free();
    const gpa = p.allocator;
    var id: u32 = 0;
    if (ok) {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        id = webstore.parseContainerId(arena.allocator(), payload);
    }
    if (id != 0) {
        const stored_id = id;
        id = createContainerAt(gpa, .{
            .id = stored_id,
            .name = p.name,
            .jar = p.name,
            .color = p.color,
            .route = webroute.Spec.parse(p.route, torEndpoint()) orelse .{ .kind = .mux },
        });
        // The daemon write happened first so it could mint the stable id.
        // If local setup cannot make the corresponding live container,
        // remove that half-committed record instead of reviving it on the
        // next launch as an apparently usable route.
        if (id == 0) _ = webstore.containerRemove(gpa, stored_id, null, &onStoreAck);
    }
    if (p.cb) |cb| cb(p.ctx, id);
}
