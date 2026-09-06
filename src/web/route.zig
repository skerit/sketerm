//! The network route a browser tab's traffic takes.
//!
//! A route is a property of a TAB, not of a container: the same identity
//! browses some tabs directly and others through Tor or a mux host. Stock
//! CEF cannot express that inside one profile — one `CefBrowserContext` is
//! one Chromium `Profile` is one `NetworkContext` is one proxy setting, and
//! the proxy layer is handed a URL and nothing else, so it can never tell
//! two tabs apart. Measured, not assumed: a storage-sharing context reports
//! `IsSame` and setting proxy B rerouted both (see `src/web/CLAUDE.md`).
//!
//! So a route is realized as a whole HELPER INSTANCE: one
//! `sketerm-webengine` process per route, each with its own profile and its
//! route's proxy. Routing is then correct by construction rather than by
//! correlation — a Tor instance has no direct path at all, and no Chromium
//! internal (connection pooling, proxy-resolution caching) can undermine it.
//! Identity is re-shared across those instances by cookie synchronisation,
//! which is a deliberate trade: routing failures would be silent and
//! dangerous, sync failures are visible and recoverable (you get logged out).
//!
//! This module is pure data — no CEF, no GTK — so it compiles into both test
//! roots and into `config.zig`.

const std = @import("std");

pub const Kind = enum {
    /// The helper's own network, no proxy.
    direct,
    /// A SOCKS5 listener speaking Tor, named by `endpoint`.
    tor,
    /// Egress through a mux/SSH host's daemon, named by `host`.
    mux,
    /// The helper PROCESS runs on `host`. This is a placement, not a
    /// route — it is kept in the same enum because it likewise selects a
    /// distinct helper instance, but its traffic leaves from that host.
    remote_browser,
};

pub const Spec = struct {
    kind: Kind = .direct,
    /// mux egress host or remote-helper host; empty for direct/tor.
    host: []const u8 = "",
    /// `host:port` of the SOCKS5 proxy; empty unless `kind == .tor`.
    endpoint: []const u8 = "",

    pub fn eql(a: Spec, b: Spec) bool {
        return a.kind == b.kind and
            std.mem.eql(u8, a.host, b.host) and
            std.mem.eql(u8, a.endpoint, b.endpoint);
    }

    pub fn isDirect(self: Spec) bool {
        return self.kind == .direct;
    }

    /// Whether the fields present match the kind. A route that fails this
    /// must never reach a helper: an empty proxy for a `.tor` route would
    /// configure NO proxy, which is a silent downgrade to direct.
    pub fn valid(self: Spec) bool {
        return switch (self.kind) {
            .direct => self.host.len == 0 and self.endpoint.len == 0,
            .tor => self.host.len == 0 and validEndpoint(self.endpoint),
            .mux, .remote_browser => validHost(self.host) and self.endpoint.len == 0,
        };
    }

    /// The proxy URL this route's helper instance is configured with, or
    /// null when the route wants no proxy at all.
    ///
    /// `.mux` returns null here on purpose: its proxy is a LOCAL bridge
    /// whose port is not known until the bridge binds, so the caller
    /// formats that one itself. Only `.tor` names a proxy up front.
    pub fn proxyUrl(self: Spec, buf: []u8) ?[]const u8 {
        return switch (self.kind) {
            .tor => std.fmt.bufPrint(buf, "socks5://{s}", .{self.endpoint}) catch null,
            .direct, .mux, .remote_browser => null,
        };
    }

    /// The user-facing spelling, one home for config, the CLI and the
    /// MCP argument: `direct` | `tor` | `via:<host>` | `on:<host>`.
    /// Tor carries no endpoint here because the endpoint is a
    /// machine-wide setting (`mux_tor_socks_endpoint`), supplied by the
    /// caller at parse time; a spec whose fields do not fit the grammar
    /// formats to null.
    pub fn format(self: Spec, buf: []u8) ?[]const u8 {
        return switch (self.kind) {
            .direct => std.fmt.bufPrint(buf, "direct", .{}) catch null,
            .tor => std.fmt.bufPrint(buf, "tor", .{}) catch null,
            .mux => if (self.host.len == 0) null else std.fmt.bufPrint(buf, "via:{s}", .{self.host}) catch null,
            .remote_browser => if (self.host.len == 0) null else std.fmt.bufPrint(buf, "on:{s}", .{self.host}) catch null,
        };
    }

    /// Inverse of `format`. `tor_endpoint` is the SOCKS5 `host:port` a
    /// `tor` spec resolves to; the returned spec borrows `text` and
    /// `tor_endpoint`. Null for anything outside the grammar, including
    /// a `tor` whose endpoint is not a valid `host:port` and a `via:` or
    /// `on:` without a host -- an unparseable route must never quietly
    /// become direct.
    pub fn parse(text: []const u8, tor_endpoint: []const u8) ?Spec {
        const t = std.mem.trim(u8, text, " \t");
        if (t.len == 0 or std.mem.eql(u8, t, "direct")) return .{};
        if (std.mem.eql(u8, t, "tor")) {
            const spec = Spec{ .kind = .tor, .endpoint = tor_endpoint };
            return if (spec.valid()) spec else null;
        }
        if (std.mem.startsWith(u8, t, "via:")) return hostSpec(.mux, t["via:".len..]);
        if (std.mem.startsWith(u8, t, "on:")) return hostSpec(.remote_browser, t["on:".len..]);
        return null;
    }

    fn hostSpec(kind: Kind, host_raw: []const u8) ?Spec {
        const host = std.mem.trim(u8, host_raw, " \t");
        if (!validHost(host)) return null;
        return .{ .kind = kind, .host = host };
    }

    /// Whether `text` is in the grammar at all, independent of which
    /// Tor endpoint is configured. What a store validates a container's
    /// stored route with: the endpoint is not the container's to know.
    pub fn validText(text: []const u8) bool {
        return parse(text, SHAPE_CHECK_ENDPOINT) != null;
    }

    /// What the tab shows next to its site button: nothing for direct
    /// (the padlock says it all), otherwise where the traffic leaves.
    pub fn describe(self: Spec, buf: []u8) []const u8 {
        return switch (self.kind) {
            .direct => "",
            .tor => "via Tor",
            .mux => std.fmt.bufPrint(buf, "via {s}", .{self.host}) catch "via server",
            .remote_browser => std.fmt.bufPrint(buf, "on {s}", .{self.host}) catch "on server",
        };
    }

    /// Icon name of a NON-direct route, null for direct: for a surface
    /// that marks routed tabs only. The always-visible route button
    /// uses `Choice.icon`, which names every route.
    pub fn icon(self: Spec) ?[*:0]const u8 {
        if (self.kind == .direct) return null;
        return Choice.fromKind(self.kind).icon();
    }

    /// What the toolbar's ALWAYS-visible route button says, direct
    /// included: a route is a fact the user must be able to read and
    /// change without opening anything, and a button that appears only
    /// once the route is non-direct is exactly the hidden switch nobody
    /// found. A host is elided to `HOST_LABEL_MAX` so the address entry
    /// keeps its width.
    pub fn shortLabel(self: Spec, buf: []u8) []const u8 {
        return switch (self.kind) {
            .direct => "Direct",
            .tor => "Tor",
            .mux => hostLabel(buf, "via ", self.host),
            .remote_browser => hostLabel(buf, "on ", self.host),
        };
    }

    /// The tab title with the route in front of it when the route is
    /// not direct (`[Tor] Example`), so the tab strip and the tree
    /// sidebar both say where a tab's traffic leaves. A title that does
    /// not fit `buf` is truncated, never dropped: the badge is the
    /// point, the tail of a long title is not.
    pub fn badgedTitle(self: Spec, buf: []u8, title: []const u8) []const u8 {
        if (self.kind == .direct) return title;
        var lbuf: [HOST_LABEL_MAX + 8]u8 = undefined;
        const label = self.shortLabel(&lbuf);
        var w = std.Io.Writer.fixed(buf);
        w.print("[{s}] ", .{label}) catch return title;
        const room = buf.len - w.buffered().len;
        w.writeAll(title[0..utf8Fit(title, room)]) catch {};
        return w.buffered();
    }

    /// A short, stable, filesystem- and socket-safe identifier.
    ///
    /// It names this route's profile directory and helper socket, so it
    /// must be STABLE across restarts (a changed slug orphans the profile
    /// and silently logs the user out of that route) and SHORT: a
    /// `sockaddr_un` path caps near 108 bytes and the runtime dir already
    /// eats most of that. Hence a hash rather than the readable fields.
    pub fn slug(self: Spec, buf: []u8) ?[]const u8 {
        if (self.kind == .direct) return std.fmt.bufPrint(buf, "direct", .{}) catch null;
        var h = std.hash.Wyhash.init(0);
        h.update(@tagName(self.kind));
        h.update("\x00");
        h.update(self.host);
        h.update("\x00");
        h.update(self.endpoint);
        return std.fmt.bufPrint(buf, "{s}-{x:0>8}", .{
            @tagName(self.kind),
            @as(u32, @truncate(h.final())),
        }) catch null;
    }
};

/// Longest host a `via:`/`on:` route may name; matches the client's
/// fixed host buffers.
pub const MAX_HOST: usize = 255;

/// Longest host `shortLabel` shows before eliding; the toolbar button
/// sits between the padlock and the address entry.
pub const HOST_LABEL_MAX: usize = 24;

/// `prefix` + host, the host elided from the middle past
/// `HOST_LABEL_MAX` (`me@very-long...box`), so both the user part and
/// the tail of the name stay readable.
fn hostLabel(buf: []u8, prefix: []const u8, host: []const u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll(prefix) catch return prefix;
    if (host.len <= HOST_LABEL_MAX) {
        w.writeAll(host) catch {};
    } else {
        const head = HOST_LABEL_MAX / 2;
        const tail = HOST_LABEL_MAX - head - 3;
        w.writeAll(host[0..utf8Fit(host, head)]) catch {};
        w.writeAll("...") catch {};
        w.writeAll(host[host.len - utf8FitTail(host, tail) ..]) catch {};
    }
    return w.buffered();
}

/// Largest byte count `<= max` that ends on a codepoint boundary.
fn utf8Fit(s: []const u8, max: usize) usize {
    var n = @min(s.len, max);
    while (n > 0 and n < s.len and (s[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// Largest byte count `<= max` from the END that starts on a boundary.
fn utf8FitTail(s: []const u8, max: usize) usize {
    var n = @min(s.len, max);
    while (n > 0 and (s[s.len - n] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// The four choices every route picker offers, in the ONE order the
/// site-info dropdown, the toolbar route menu and the palette agree
/// on. A choice is a kind plus whether it needs a host typed; the
/// `Spec` it becomes is minted by `spec`, so no picker carries its own
/// kind table.
pub const Choice = enum(u8) {
    direct = 0,
    tor = 1,
    via = 2,
    on = 3,

    pub const all = [_]Choice{ .direct, .tor, .via, .on };

    pub fn fromKind(k: Kind) Choice {
        return switch (k) {
            .direct => .direct,
            .tor => .tor,
            .mux => .via,
            .remote_browser => .on,
        };
    }

    pub fn kind(self: Choice) Kind {
        return switch (self) {
            .direct => .direct,
            .tor => .tor,
            .via => .mux,
            .on => .remote_browser,
        };
    }

    /// The row / dropdown text.
    pub fn label(self: Choice) [*:0]const u8 {
        return switch (self) {
            .direct => "Direct",
            .tor => "Tor",
            .via => "Via server",
            .on => "Browser runs on",
        };
    }

    /// One line under the row text saying what the choice means.
    pub fn detail(self: Choice) [*:0]const u8 {
        return switch (self) {
            .direct => "This machine's own network",
            .tor => "Anonymised through the Tor network",
            .via => "Traffic leaves from a mux/SSH host",
            .on => "The whole browser runs on a host",
        };
    }

    /// Icon for the row and for the toolbar button when this is the
    /// current choice; never null, unlike `Spec.icon`, because the
    /// button is always there. Names sketerm SHIPS (`data/icons`):
    /// the Adwaita `network-*-symbolic` names resolve on no other
    /// theme chain, and the first GUI run of the route button showed
    /// the broken-image glyph for exactly that reason.
    pub fn icon(self: Choice) [*:0]const u8 {
        return switch (self) {
            .direct => "sketerm-route-direct-symbolic",
            .tor => "sketerm-route-tor-symbolic",
            .via => "sketerm-route-via-symbolic",
            .on => "sketerm-route-on-symbolic",
        };
    }

    /// The two host-bound choices cannot be applied from a one-click
    /// row: they need a host typed first.
    pub fn needsHost(self: Choice) bool {
        return self == .via or self == .on;
    }

    /// The spec this choice realizes. `host` is read only by the
    /// host-bound choices and `tor_endpoint` only by `.tor`; the result
    /// borrows both. Null when the choice needs a host and none was
    /// given, or the Tor endpoint is not a valid `host:port` -- the
    /// same refusals `Spec.parse` makes.
    pub fn spec(self: Choice, host: []const u8, tor_endpoint: []const u8) ?Spec {
        const s: Spec = switch (self) {
            .direct => .{},
            .tor => .{ .kind = .tor, .endpoint = tor_endpoint },
            .via => .{ .kind = .mux, .host = host },
            .on => .{ .kind = .remote_browser, .host = host },
        };
        return if (s.valid()) s else null;
    }
};

/// A syntactically valid endpoint used ONLY to check a `tor` text's
/// shape where no real endpoint applies (`validText`).
const SHAPE_CHECK_ENDPOINT = "127.0.0.1:9050";

/// A mux host spec (`user@box`, `ssh:box`, ...): non-empty, bounded,
/// and never containing whitespace, a slash or a control byte.
fn validHost(host: []const u8) bool {
    if (host.len == 0 or host.len > MAX_HOST) return false;
    for (host) |ch| {
        if (ch <= ' ' or ch == '/' or ch == 0x7f) return false;
    }
    return true;
}

/// `host:port` with a numeric-or-name host and a nonzero port. Bracketed
/// IPv6 is accepted; a bare `::1:9050` is not, because its last colon is
/// ambiguous.
fn validEndpoint(text: []const u8) bool {
    if (text.len == 0) return false;
    const colon = if (text[0] == '[') blk: {
        const close = std.mem.indexOfScalar(u8, text, ']') orelse return false;
        if (close <= 1 or close + 1 >= text.len or text[close + 1] != ':') return false;
        break :blk close + 1;
    } else blk: {
        const idx = std.mem.lastIndexOfScalar(u8, text, ':') orelse return false;
        if (std.mem.indexOfScalar(u8, text[0..idx], ':') != null) return false;
        break :blk idx;
    };
    if (colon == 0 or colon + 1 >= text.len) return false;
    const port = std.fmt.parseInt(u16, text[colon + 1 ..], 10) catch return false;
    return port != 0;
}

test "route equality distinguishes every field" {
    const t = std.testing;
    const tor_a = Spec{ .kind = .tor, .endpoint = "127.0.0.1:9050" };
    const tor_b = Spec{ .kind = .tor, .endpoint = "127.0.0.1:9150" };
    try t.expect(tor_a.eql(tor_a));
    try t.expect(!tor_a.eql(tor_b));
    try t.expect(!tor_a.eql(.{}));
    try t.expect(!(Spec{ .kind = .mux, .host = "a" }).eql(.{ .kind = .mux, .host = "b" }));
    // A mux egress and a remote helper on the same host are NOT the same
    // route: one proxies traffic, the other moves the whole browser.
    try t.expect(!(Spec{ .kind = .mux, .host = "a" }).eql(.{ .kind = .remote_browser, .host = "a" }));
}

test "an invalid route is rejected rather than silently downgraded" {
    const t = std.testing;
    try t.expect((Spec{}).valid());
    try t.expect((Spec{ .kind = .tor, .endpoint = "127.0.0.1:9050" }).valid());
    try t.expect((Spec{ .kind = .tor, .endpoint = "[::1]:9050" }).valid());
    try t.expect((Spec{ .kind = .mux, .host = "me@box" }).valid());

    // The dangerous one: a Tor route with no proxy would configure none.
    try t.expect(!(Spec{ .kind = .tor }).valid());
    try t.expect(!(Spec{ .kind = .tor, .endpoint = "127.0.0.1:0" }).valid());
    try t.expect(!(Spec{ .kind = .tor, .endpoint = "nocolon" }).valid());
    try t.expect(!(Spec{ .kind = .tor, .endpoint = "::1:9050" }).valid());
    try t.expect(!(Spec{ .kind = .mux }).valid());
    try t.expect(!(Spec{ .kind = .direct, .host = "box" }).valid());
}

test "a route's proxy url is only minted where the route names one" {
    const t = std.testing;
    var buf: [128]u8 = undefined;
    try t.expectEqualStrings(
        "socks5://127.0.0.1:9050",
        (Spec{ .kind = .tor, .endpoint = "127.0.0.1:9050" }).proxyUrl(&buf).?,
    );
    try t.expect((Spec{}).proxyUrl(&buf) == null);
    // mux binds a local bridge first; its port is not known here.
    try t.expect((Spec{ .kind = .mux, .host = "box" }).proxyUrl(&buf) == null);
}

test "slugs are stable, distinct, and short enough for a unix socket path" {
    const t = std.testing;
    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;

    const tor = Spec{ .kind = .tor, .endpoint = "127.0.0.1:9050" };
    const first = tor.slug(&a).?;
    const second = tor.slug(&b).?;
    try t.expectEqualStrings(first, second); // stable across calls

    try t.expectEqualStrings("direct", (Spec{}).slug(&a).?);

    // Distinct routes must not share a profile directory.
    const other = Spec{ .kind = .tor, .endpoint = "127.0.0.1:9150" };
    try t.expect(!std.mem.eql(u8, tor.slug(&a).?, other.slug(&b).?));
    const mux = Spec{ .kind = .mux, .host = "box" };
    try t.expect(!std.mem.eql(u8, mux.slug(&a).?, (Spec{ .kind = .remote_browser, .host = "box" }).slug(&b).?));

    // Long inputs must not grow the slug: it lives inside a sun_path.
    const long = Spec{ .kind = .mux, .host = "a" ** 200 };
    try t.expect(long.slug(&a).?.len <= 24);
}

test "route text round-trips through parse and format" {
    const t = std.testing;
    var buf: [300]u8 = undefined;
    const ep = "127.0.0.1:9050";
    const direct = Spec.parse("direct", ep).?;
    try t.expect(direct.isDirect());
    try t.expectEqualStrings("direct", direct.format(&buf).?);
    try t.expect(Spec.parse("", ep).?.isDirect());

    const tor = Spec.parse("tor", ep).?;
    try t.expectEqual(Kind.tor, tor.kind);
    try t.expectEqualStrings(ep, tor.endpoint);
    try t.expectEqualStrings("tor", tor.format(&buf).?);

    const via = Spec.parse("via:me@box", ep).?;
    try t.expectEqual(Kind.mux, via.kind);
    try t.expectEqualStrings("me@box", via.host);
    try t.expectEqualStrings("via:me@box", via.format(&buf).?);

    const on = Spec.parse(" on:udp:box ", ep).?;
    try t.expectEqual(Kind.remote_browser, on.kind);
    try t.expectEqualStrings("udp:box", on.host);
    try t.expectEqualStrings("on:udp:box", on.format(&buf).?);
}

test "route text outside the grammar is refused, never downgraded" {
    const t = std.testing;
    const ep = "127.0.0.1:9050";
    try t.expect(Spec.parse("via:", ep) == null);
    try t.expect(Spec.parse("on:", ep) == null);
    try t.expect(Spec.parse("via:a b", ep) == null);
    try t.expect(Spec.parse("proxy:box", ep) == null);
    try t.expect(Spec.parse("Tor", ep) == null);
    // A tor route is only as good as its endpoint.
    try t.expect(Spec.parse("tor", "") == null);
    try t.expect(Spec.parse("tor", "nocolon") == null);
    try t.expect(Spec.validText("tor"));
    try t.expect(Spec.validText("via:box"));
    try t.expect(!Spec.validText("bogus"));
    // A host-kind spec with no host has no spelling.
    var buf: [64]u8 = undefined;
    try t.expect((Spec{ .kind = .mux }).format(&buf) == null);
}

test "the indicator names where traffic leaves" {
    const t = std.testing;
    var buf: [300]u8 = undefined;
    try t.expectEqualStrings("", (Spec{}).describe(&buf));
    try t.expectEqualStrings("via Tor", (Spec{ .kind = .tor, .endpoint = "127.0.0.1:9050" }).describe(&buf));
    try t.expectEqualStrings("via box", (Spec{ .kind = .mux, .host = "box" }).describe(&buf));
    try t.expectEqualStrings("on box", (Spec{ .kind = .remote_browser, .host = "box" }).describe(&buf));
    try t.expect((Spec{}).icon() == null);
    try t.expect((Spec{ .kind = .tor }).icon() != null);
}

test "the toolbar button names every route, direct included" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("Direct", (Spec{}).shortLabel(&buf));
    try t.expectEqualStrings("Tor", (Spec{ .kind = .tor, .endpoint = "127.0.0.1:9050" }).shortLabel(&buf));
    try t.expectEqualStrings("via me@box", (Spec{ .kind = .mux, .host = "me@box" }).shortLabel(&buf));
    try t.expectEqualStrings("on box", (Spec{ .kind = .remote_browser, .host = "box" }).shortLabel(&buf));
    // A long host is elided from the middle, never truncated to nothing.
    const long = Spec{ .kind = .mux, .host = "someone@a-very-long-hostname.internal.example" };
    const l = long.shortLabel(&buf);
    try t.expect(l.len <= "via ".len + HOST_LABEL_MAX);
    try t.expect(std.mem.startsWith(u8, l, "via someone@"));
    try t.expect(std.mem.endsWith(u8, l, "example"));
    try t.expect(std.mem.indexOf(u8, l, "...") != null);
}

test "a routed tab's title carries a badge, a direct one is untouched" {
    const t = std.testing;
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("Example", (Spec{}).badgedTitle(&buf, "Example"));
    try t.expectEqualStrings("[Tor] Example", (Spec{ .kind = .tor, .endpoint = "127.0.0.1:9050" }).badgedTitle(&buf, "Example"));
    try t.expectEqualStrings("[via box] Example", (Spec{ .kind = .mux, .host = "box" }).badgedTitle(&buf, "Example"));
    try t.expectEqualStrings("[on box] Example", (Spec{ .kind = .remote_browser, .host = "box" }).badgedTitle(&buf, "Example"));
    // Truncation lands on a codepoint boundary.
    var tiny: [12]u8 = undefined;
    const cut = (Spec{ .kind = .tor, .endpoint = "127.0.0.1:9050" }).badgedTitle(&tiny, "caf\xc3\xa9\xc3\xa9\xc3\xa9");
    try t.expect(std.unicode.utf8ValidateSlice(cut));
    try t.expect(std.mem.startsWith(u8, cut, "[Tor] caf"));
}

test "Choice is the one order every picker shares and mints valid specs" {
    const t = std.testing;
    const ep = "127.0.0.1:9050";
    try t.expectEqual(Choice.direct, Choice.fromKind(.direct));
    try t.expectEqual(Choice.via, Choice.fromKind(.mux));
    try t.expectEqual(Choice.on, Choice.fromKind(.remote_browser));
    inline for (Choice.all) |ch| try t.expectEqual(ch, Choice.fromKind(ch.kind()));
    try t.expect(!Choice.direct.needsHost());
    try t.expect(!Choice.tor.needsHost());
    try t.expect(Choice.via.needsHost());
    try t.expect(Choice.on.needsHost());

    try t.expect(Choice.direct.spec("", ep).?.isDirect());
    try t.expectEqualStrings(ep, Choice.tor.spec("", ep).?.endpoint);
    try t.expectEqualStrings("box", Choice.via.spec("box", ep).?.host);
    try t.expectEqual(Kind.remote_browser, Choice.on.spec("box", ep).?.kind);
    // The same refusals the text grammar makes.
    try t.expect(Choice.via.spec("", ep) == null);
    try t.expect(Choice.on.spec("a b", ep) == null);
    try t.expect(Choice.tor.spec("", "") == null);
    // What a choice mints round-trips through the text grammar.
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("via:box", Choice.via.spec("box", ep).?.format(&buf).?);
    try t.expect(Spec.parse("on:box", ep).?.eql(Choice.on.spec("box", ep).?));
}
