//! Which application identity a binary was invoked as.
//!
//! One executable ships under several names: `sketerm`, plus the
//! `sketerm-files` / `sketerm-web` / `sketerm-viewer` / `sketerm-editor`
//! identity hardlinks, each of which is its own GApplication id and
//! `StartupWMClass`. Every mode therefore answers the same question the
//! same way: argv0's BASENAME is my identity (index 1 is the first of
//! my own arguments), or argv[1] is one of my subcommand spellings
//! (index 2), or this invocation is not mine at all.
//!
//! Matching argv0 on the basename and never on a substring is the
//! load-bearing part: a path like `/opt/sketerm-web/bin/sketerm` is the
//! terminal, and `sketerm-webengine` is the CEF helper, not the browser.

const std = @import("std");

/// The last path component of `argv0`, or all of it when there is no `/`.
pub fn baseName(argv0: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, argv0, '/')) |slash|
        argv0[slash + 1 ..]
    else
        argv0;
}

/// Index of the first argument belonging to this identity.
/// @return 1 when argv0 IS `binary`, 2 when argv[1] is one of
/// `subcommands`, null when this is another entry point.
pub fn start(args: []const []const u8, binary: []const u8, subcommands: []const []const u8) ?usize {
    if (args.len == 0) return null;
    if (std.mem.eql(u8, baseName(args[0]), binary)) return 1;
    if (args.len > 1) {
        for (subcommands) |word| {
            if (std.mem.eql(u8, args[1], word)) return 2;
        }
    }
    return null;
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "baseName takes the last component only" {
    try t.expectEqualStrings("sketerm-web", baseName("sketerm-web"));
    try t.expectEqualStrings("sketerm-web", baseName("/usr/bin/sketerm-web"));
    try t.expectEqualStrings("sketerm", baseName("/opt/sketerm-web/bin/sketerm"));
    try t.expectEqualStrings("", baseName("/usr/bin/"));
}

test "start matches every shipped identity and refuses the others" {
    const web: []const []const u8 = &.{"web"};
    const view: []const []const u8 = &.{ "view", "viewer" };

    // argv0 identity, bare and absolute.
    try t.expectEqual(@as(?usize, 1), start(&.{"sketerm-web"}, "sketerm-web", web));
    try t.expectEqual(@as(?usize, 1), start(&.{"/usr/bin/sketerm-web"}, "sketerm-web", web));
    // Subcommand form, every spelling.
    try t.expectEqual(@as(?usize, 2), start(&.{ "sketerm", "web" }, "sketerm-web", web));
    try t.expectEqual(@as(?usize, 2), start(&.{ "sketerm", "view", "f" }, "sketerm-viewer", view));
    try t.expectEqual(@as(?usize, 2), start(&.{ "sketerm", "viewer", "f" }, "sketerm-viewer", view));
    // Other identities are not this one.
    try t.expectEqual(@as(?usize, null), start(&.{"sketerm"}, "sketerm-web", web));
    try t.expectEqual(@as(?usize, null), start(&.{"sketerm-files"}, "sketerm-web", web));
    try t.expectEqual(@as(?usize, null), start(&.{"/usr/bin/sketerm-viewer"}, "sketerm-web", web));
    // The CEF helper is NOT the browser identity, despite the prefix.
    try t.expectEqual(@as(?usize, null), start(&.{"sketerm-webengine"}, "sketerm-web", web));
    // Another subcommand, and an empty argv.
    try t.expectEqual(@as(?usize, null), start(&.{ "sketerm", "mux" }, "sketerm-web", web));
    try t.expectEqual(@as(?usize, null), start(&.{}, "sketerm-web", web));
    // No subcommands at all is legal.
    try t.expectEqual(@as(?usize, null), start(&.{ "sketerm", "web" }, "sketerm-web", &.{}));
}

/// True when the argument list explicitly asks for help. Callers pair it
/// with the subcommand's own "this was the usage path" predicate: an
/// explicit --help is a successful request (exit 0), a missing operand
/// that printed the same usage is not.
pub fn helpRequested(args: []const []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return true;
    }
    return false;
}

test "helpRequested accepts both spellings anywhere in the list" {
    try t.expect(helpRequested(&.{"--help"}));
    try t.expect(helpRequested(&.{"-h"}));
    try t.expect(helpRequested(&.{ "host", "--help" }));
    try t.expect(helpRequested(&.{ "-h", "host" }));
}

test "helpRequested refuses near misses and an empty list" {
    try t.expect(!helpRequested(&.{}));
    try t.expect(!helpRequested(&.{ "host", "ls" }));
    try t.expect(!helpRequested(&.{"--help-me"}));
    try t.expect(!helpRequested(&.{"-help"}));
    try t.expect(!helpRequested(&.{"help"}));
    try t.expect(!helpRequested(&.{"-hx"}));
}
