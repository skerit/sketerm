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

pub const ID_SUFFIX = ".web";
pub const APP_NAME = "Sketerm Web";

pub const Request = struct {
    allocator: std.mem.Allocator,
    /// Addresses in command-line order, owned. The first opens in the
    /// window's first tab, the rest in additional tabs. Empty = one
    /// blank tab with the address entry focused.
    urls: [][]u8 = &.{},
    /// `--help` / `-h`: print usage and do nothing else.
    help: bool = false,

    pub fn empty(allocator: std.mem.Allocator) Request {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Request) void {
        for (self.urls) |u| self.allocator.free(u);
        if (self.urls.len > 0) self.allocator.free(self.urls);
        self.urls = &.{};
    }
};

/// Index of the first `sketerm web` argument, or null for another
/// entry point. Unlike the file manager there is no dedicated binary
/// name to match: `sketerm-web` is already the CEF helper this face
/// talks to, so the subcommand word is the only spelling.
pub fn invocationStart(args: []const []const u8) ?usize {
    if (args.len > 1 and std.mem.eql(u8, args[1], "web")) return 2;
    return null;
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
    for (args[start..]) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            req.help = true;
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
