//! GTK-free half of the `sketerm web` entry point: recognising the
//! invocation and turning its arguments into the URLs the first
//! window's web tabs open. main.zig owns the GApplication side,
//! ui/webface.zig the face itself — `sketerm web` is an IDENTITY
//! wrapper around the ordinary web face, never a second implementation.
//!
//! Mirrors `editor_app.zig` / `viewer.zig`, minus the `--here`/`--tab`
//! modes: a web page has no invoking pane to inherit anything from, and
//! the palette actions (`new_web_tab` / `new_web_split`) already put a
//! face in a terminal window.

const std = @import("std");
const invocation = @import("util/invocation.zig");
const webroute = @import("web/route.zig");

pub const ID_SUFFIX = ".web";
/// The identity hardlink's name, like `sketerm-files`. The CEF helper
/// is `sketerm-webengine`, so this name is free -- and basename
/// matching is what keeps the two apart.
pub const BINARY_NAME = "sketerm-web";
pub const APP_NAME = "Sketerm Web";

pub const Request = struct {
    allocator: std.mem.Allocator,
    /// Addresses in command-line order, owned. The first opens in the
    /// window's first tab, the rest in additional tabs. Empty = one
    /// blank tab with the address entry focused.
    urls: [][]u8 = &.{},
    /// `--help` / `-h`: print usage and do nothing else.
    help: bool = false,
    /// `--route <text>`: the route every tab of this invocation is
    /// born on, in the one grammar of `web/route.zig` (`direct` |
    /// `tor` | `via:<host>` | `on:<host>`), owned. Null = the
    /// configured default (`web_route`, or the container's).
    route: ?[]u8 = null,
    /// `--route` was given text outside the grammar (or no text at
    /// all): the invocation must be refused with a message, never run
    /// on the default route. Owned; the offending text.
    bad_route: ?[]u8 = null,

    pub fn empty(allocator: std.mem.Allocator) Request {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Request) void {
        for (self.urls) |u| self.allocator.free(u);
        if (self.urls.len > 0) self.allocator.free(self.urls);
        self.urls = &.{};
        if (self.route) |r| self.allocator.free(r);
        self.route = null;
        if (self.bad_route) |r| self.allocator.free(r);
        self.bad_route = null;
    }
};

/// What `--route` accepts, for the usage text and the refusal message.
pub const ROUTE_GRAMMAR = "direct | tor | via:<host> | on:<host>";

/// Index of the first `sketerm web` argument, or null for another
/// entry point. Both spellings count, exactly like the file manager:
/// the `sketerm-web` identity hardlink (argv0) and the subcommand
/// word. The CEF helper is `sketerm-webengine` so this name is free.
pub fn invocationStart(args: []const []const u8) ?usize {
    return invocation.start(args, BINARY_NAME, &.{"web"});
}

/// Collect the addresses of a `sketerm web ...` invocation, or null
/// when this is not one. Arguments pass through verbatim: the face's
/// own address-bar normalisation decides what a bare `example.com` or
/// a search phrase means, and duplicating that here would let the two
/// disagree.
pub fn collect(allocator: std.mem.Allocator, args: []const []const u8) !?Request {
    const start = invocationStart(args) orelse return null;
    var req = Request.empty(allocator);
    errdefer req.deinit();

    var urls: std.ArrayList([]u8) = .empty;
    errdefer {
        for (urls.items) |u| allocator.free(u);
        urls.deinit(allocator);
    }
    var i: usize = start;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            req.help = true;
            continue;
        }
        // `--route tor` and `--route=tor`. The text is only shape-checked
        // here (`validText`): whether `tor` can actually be dialed is
        // the window's question, since the endpoint lives in config.
        const route_text: ?[]const u8 = if (std.mem.eql(u8, a, "--route")) blk: {
            i += 1;
            break :blk if (i < args.len) args[i] else "";
        } else if (std.mem.startsWith(u8, a, "--route="))
            a["--route=".len..]
        else
            null;
        if (route_text) |text| {
            const owned = try allocator.dupe(u8, text);
            // `validText` accepts "" as direct (the config default's
            // spelling); a bare `--route` on the command line is a
            // mistake, not a request for direct.
            if (text.len != 0 and webroute.Spec.validText(text)) {
                if (req.route) |old| allocator.free(old);
                req.route = owned;
            } else {
                if (req.bad_route) |old| allocator.free(old);
                req.bad_route = owned;
            }
            continue;
        }
        if (a.len == 0 or a[0] == '-') continue;
        const owned = try allocator.dupe(u8, a);
        errdefer allocator.free(owned);
        try urls.append(allocator, owned);
    }
    req.urls = try urls.toOwnedSlice(allocator);
    return req;
}

test "invocationStart only matches the web subcommand" {
    try std.testing.expectEqual(@as(?usize, 2), invocationStart(&.{ "sketerm", "web" }));
    try std.testing.expectEqual(@as(?usize, 2), invocationStart(&.{ "/usr/bin/sketerm", "web", "example.com" }));
    try std.testing.expectEqual(@as(?usize, null), invocationStart(&.{ "sketerm", "files" }));
    try std.testing.expectEqual(@as(?usize, null), invocationStart(&.{"sketerm"}));
}

test "invocationStart matches the sketerm-web identity hardlink" {
    try std.testing.expectEqual(@as(?usize, 1), invocationStart(&.{"sketerm-web"}));
    try std.testing.expectEqual(@as(?usize, 1), invocationStart(&.{ "/usr/bin/sketerm-web", "example.com" }));
    // Only the exact basename counts; the CEF helper rename must never
    // be picked up, and neither must arbitrary prefixes.
    try std.testing.expectEqual(@as(?usize, null), invocationStart(&.{"sketerm-webengine"}));
    try std.testing.expectEqual(@as(?usize, null), invocationStart(&.{"my-sketerm-web-thing"}));
}

test "collect keeps positional urls in order and skips flags" {
    const alloc = std.testing.allocator;
    var req = (try collect(alloc, &.{ "sketerm", "web", "https://example.com", "--help", "b.example" })).?;
    defer req.deinit();
    try std.testing.expect(req.help);
    try std.testing.expectEqual(@as(usize, 2), req.urls.len);
    try std.testing.expectEqualStrings("https://example.com", req.urls[0]);
    try std.testing.expectEqualStrings("b.example", req.urls[1]);

    try std.testing.expect((try collect(alloc, &.{ "sketerm", "--version" })) == null);
}

test "collect takes --route in the one route grammar and refuses the rest" {
    const alloc = std.testing.allocator;
    var req = (try collect(alloc, &.{ "sketerm", "web", "--route", "tor", "https://example.com" })).?;
    defer req.deinit();
    try std.testing.expectEqualStrings("tor", req.route.?);
    try std.testing.expect(req.bad_route == null);
    try std.testing.expectEqual(@as(usize, 1), req.urls.len);
    // The route value is never mistaken for an address.
    try std.testing.expectEqualStrings("https://example.com", req.urls[0]);

    var eq = (try collect(alloc, &.{ "sketerm-web", "--route=via:me@box", "a.example" })).?;
    defer eq.deinit();
    try std.testing.expectEqualStrings("via:me@box", eq.route.?);

    // Outside the grammar: refused, not silently direct.
    var bad = (try collect(alloc, &.{ "sketerm", "web", "--route", "proxy:box" })).?;
    defer bad.deinit();
    try std.testing.expect(bad.route == null);
    try std.testing.expectEqualStrings("proxy:box", bad.bad_route.?);
    var missing = (try collect(alloc, &.{ "sketerm", "web", "--route" })).?;
    defer missing.deinit();
    try std.testing.expectEqualStrings("", missing.bad_route.?);
}
