//! A route's way out for clients outside the browser (`web_route_exit`).
//!
//! A `via:<host>` route leaves through that host's daemon, and the browser
//! reaches it through a loopback SOCKS5 bridge (`socksbridge.Egress`). A
//! caller that makes its own connections (an HTTP client beside the
//! browser) gets a bridge of the same kind here, so its traffic leaves from
//! the same host and its names resolve there. `tor` and `proxy:` routes
//! already name a proxy and are answered with it; `direct` needs none;
//! `on:` places a browser on a host and has no exit to hand out.
//!
//! Bridges are kept per host for the life of this process, so every caller
//! of one route shares one bridge and one mux connection. A bridge whose
//! connect failed or whose connection dropped never serves again
//! (`Egress.isServing`); the next ask replaces it, so a host that came back
//! is reached again without restarting anything. Like the browser's own
//! bridge, the listener is loopback-only and takes no credentials.

const std = @import("std");
const webroute = @import("../web/route.zig");
const socksbridge = @import("socksbridge.zig");
const client = @import("../mux/client.zig");

const gpa = std.heap.c_allocator;

/// How many hosts' bridges one process keeps at once.
pub const MAX_EXITS: usize = 16;

/// How the bridge reaches a host's daemon (`mux_cli.muxConnect` in the server).
pub const ConnectFn = *const fn (allocator: std.mem.Allocator, host: ?[]const u8) ?client.Conn;

const Exit = struct {
    host: []u8,
    egress: *socksbridge.Egress,
};

var g_exits: std.ArrayList(Exit) = .empty;

/// The loopback port of a `via:` host's bridge.
pub const Bridged = struct {
    port: u16,
    /// Whether a serving bridge of an earlier ask was handed out again.
    reused: bool,
};

pub const BridgeError = error{ BridgeFailed, TooManyExits };

/// The bridge of `host`, made (or remade, when the last one stopped
/// serving) on demand. Bridges that stopped are dropped first, so only
/// serving ones count against `MAX_EXITS`. Main thread only.
pub fn bridgeFor(host: []const u8, connectFn: ConnectFn) BridgeError!Bridged {
    var i: usize = 0;
    while (i < g_exits.items.len) {
        const exit = g_exits.items[i];
        if (exit.egress.isServing()) {
            i += 1;
            continue;
        }
        exit.egress.close();
        gpa.free(exit.host);
        _ = g_exits.swapRemove(i);
    }
    for (g_exits.items) |exit| {
        if (std.mem.eql(u8, exit.host, host)) return .{ .port = exit.egress.port(), .reused = true };
    }
    if (g_exits.items.len >= MAX_EXITS) return error.TooManyExits;

    var egress: ?*socksbridge.Egress = null;
    var buf: [64]u8 = undefined;
    _ = socksbridge.routeProxy(gpa, .{ .kind = .mux, .host = host }, &egress, connectFn, &buf) catch
        return error.BridgeFailed;
    const made = egress orelse return error.BridgeFailed;
    const owned = gpa.dupe(u8, host) catch {
        made.close();
        return error.BridgeFailed;
    };
    const port = made.port();
    g_exits.append(gpa, .{ .host = owned, .egress = made }) catch {
        gpa.free(owned);
        made.close();
        return error.BridgeFailed;
    };
    return .{ .port = port, .reused = false };
}

/// Closes every bridge (tests; a server simply exits).
pub fn closeAll() void {
    for (g_exits.items) |exit| {
        exit.egress.close();
        gpa.free(exit.host);
    }
    g_exits.clearRetainingCapacity();
}

/// Whether `web_route_exit` answers a kind: every kind but `on:`, which
/// places a browser rather than routing connections.
pub fn hasExit(kind: webroute.Kind) bool {
    return switch (kind) {
        .direct, .tor, .mux, .proxy => true,
        .remote_browser => false,
    };
}

/// The route words `web_route_exit` answers (`hasExit`), for the
/// `web_route_exit` capability fact.
pub const EXIT_WORDS = blk: {
    var n: usize = 0;
    for (std.enums.values(webroute.Kind)) |k| {
        if (hasExit(k)) n += 1;
    }
    var words: [n][]const u8 = undefined;
    var i: usize = 0;
    for (std.enums.values(webroute.Kind)) |k| {
        if (!hasExit(k)) continue;
        words[i] = k.word();
        i += 1;
    }
    break :blk words;
};

/// The proxy url a client dials for a route that names its own proxy, in
/// the `socks5h://`/`http://` spelling: the proxy resolves every host.
/// Null for every other kind (`direct` needs none, `via:` is bridged, `on:`
/// has none).
pub fn namedProxy(spec: webroute.Spec, buf: []u8) ?[]const u8 {
    return switch (spec.kind) {
        .tor => std.fmt.bufPrint(buf, "socks5h://{s}", .{spec.endpoint}) catch null,
        .proxy => std.fmt.bufPrint(buf, "{s}", .{spec.endpoint}) catch null,
        .direct, .mux, .remote_browser => null,
    };
}

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const clock = @import("../util/clock.zig");
const c = @import("../c.zig").c;

var test_release = std.atomic.Value(bool).init(false);

/// A host that never answers until the test lets go, then refuses.
fn testParkedConnect(_: std.mem.Allocator, _: ?[]const u8) ?client.Conn {
    while (!test_release.load(.acquire)) _ = c.usleep(1_000);
    return null;
}

fn testRefusedConnect(_: std.mem.Allocator, _: ?[]const u8) ?client.Conn {
    return null;
}

test "one bridge per host, shared while it serves, replaced once it stopped" {
    const t = std.testing;
    defer closeAll();
    test_release.store(false, .release);
    // Registered after closeAll so it runs first: a failed expectation
    // must still let the parked workers go.
    defer test_release.store(true, .release);

    const first = try bridgeFor("hosta", testParkedConnect);
    try t.expect(!first.reused);
    try t.expect(first.port != 0);
    const again = try bridgeFor("hosta", testParkedConnect);
    try t.expect(again.reused);
    try t.expectEqual(first.port, again.port);

    const other = try bridgeFor("hostb", testRefusedConnect);
    try t.expect(!other.reused);
    try t.expect(other.port != 0);
    try t.expect(other.port != first.port);

    // The refused connect ends hostb's worker: the next ask makes a new bridge.
    const deadline = clock.nowMs() + 2_000;
    while (g_exits.items[1].egress.isServing() and clock.nowMs() < deadline) _ = c.usleep(1_000);
    try t.expect(!g_exits.items[1].egress.isServing());
    // The worker zeroed its bridge's port on the way out; the handed-out
    // port is the one bound at create, never 0.
    try t.expectEqual(other.port, g_exits.items[1].egress.port());
    const remade = try bridgeFor("hostb", testRefusedConnect);
    try t.expect(!remade.reused);
    try t.expectEqual(@as(usize, 2), g_exits.items.len);
}

test "a route that names its proxy is answered with it, resolving remotely" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    const tor = webroute.Spec.parse("tor", "127.0.0.1:9050").?;
    try t.expectEqualStrings("socks5h://127.0.0.1:9050", namedProxy(tor, &buf).?);
    const socks = webroute.Spec.parse("proxy:socks5h://10.0.0.2:1080", "").?;
    try t.expectEqualStrings("socks5h://10.0.0.2:1080", namedProxy(socks, &buf).?);
    const http = webroute.Spec.parse("proxy:http://proxy.example:3128", "").?;
    try t.expectEqualStrings("http://proxy.example:3128", namedProxy(http, &buf).?);
    try t.expect(namedProxy(webroute.Spec.parse("direct", "").?, &buf) == null);
    try t.expect(namedProxy(webroute.Spec.parse("via:box", "").?, &buf) == null);
    try t.expect(namedProxy(webroute.Spec.parse("on:box", "").?, &buf) == null);
}

test "the serving bridges a process keeps are bounded" {
    const t = std.testing;
    defer closeAll();
    test_release.store(false, .release);
    defer test_release.store(true, .release);
    var name_buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < MAX_EXITS) : (i += 1) {
        _ = try bridgeFor(try std.fmt.bufPrint(&name_buf, "h{d}", .{i}), testParkedConnect);
    }
    try t.expectError(error.TooManyExits, bridgeFor("one-more", testParkedConnect));
    // A host already bridged is still answered at the bound.
    try t.expect((try bridgeFor("h0", testParkedConnect)).reused);
}
