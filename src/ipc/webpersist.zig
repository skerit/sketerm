//! What a web_* call leaves behind: whether the identity a tab browses in
//! persists (where its jar lives, when it reaches disk), and whether a
//! file a call wrote outlives this MCP instance. ONE vocabulary and ONE
//! derivation for every reply that states it (`mcp_web.tabEcho`, web_tabs,
//! web_fetch, web_profiles); libc-free, both test roots.
//!
//! Measured, not assumed: the headless DEFAULT identity (context 0) is
//! durable whenever the helper's data root is the durable profile store.
//! CEF's header calls an empty `cache_path` "incognito", but with
//! `root_cache_path` set the global context's cookies and localStorage
//! land in `<root>/Default` and survive a graceful helper restart
//! (smoke-mcp WEBPERSIST proves it). Only an engine WITHOUT a store keeps
//! that data in the instance directory.

const std = @import("std");
const webprofiles = @import("webprofiles.zig");
const web_proto = @import("../web/protocol.zig");

/// Which identity a tab browses in. `profile_kind` is the name of the
/// headless members.
pub const Identity = enum {
    /// The engine's shared jar (context 0); web_fetch tabs use it too.
    default,
    named,
    ephemeral,
    /// The user's own GUI browser: one of its containers, which the GUI
    /// does not report to this server.
    gui,

    pub fn headless(self: Identity) bool {
        return self != .gui;
    }
};

/// When a durable jar reaches disk.
pub const Flush = enum {
    /// Every `FLUSH_INTERVAL_S`, on web_profile_save, and at a graceful
    /// helper exit (helper capability flush-store).
    periodic,
    /// A helper without flush-store: Chromium's own commit timer (~30s)
    /// and a graceful helper exit only; web_profile_save is refused.
    graceful_exit,
    /// Held in memory; nothing is written.
    never,

    pub fn describe(self: Flush) []const u8 {
        return switch (self) {
            .periodic => std.fmt.comptimePrint("written to disk every {d}s, on web_profile_save and when the browser helper exits gracefully", .{FLUSH_INTERVAL_S}),
            .graceful_exit => "written to disk only by Chromium's own commit timer and a graceful browser helper exit (this helper cannot flush on request)",
            .never => "never written to disk",
        };
    }
};

pub const FLUSH_INTERVAL_S: i64 = @divExact(web_proto.FLUSH_INTERVAL_MS, 1000);

/// Where the engine keeps its data (`--cache-dir`), as far as this server
/// knows.
pub const Root = union(enum) {
    /// The durable profile store root (under `$XDG_STATE_HOME`).
    durable: []const u8,
    /// No durable store: the data root sits in the MCP instance directory.
    /// `why` is the store's refusal sentence.
    instance: struct { path: []const u8, why: []const u8 },
    /// Untrusted browsing: a private root deleted when the engine stops.
    private,
    /// Not known to this server; the reason.
    unknown: []const u8,
};

/// The facts `derive` reads, gathered by the caller from the view and
/// its engine.
pub const Facts = struct {
    identity: Identity,
    profile: []const u8 = "",
    /// The persisted context id of a named profile (half its jar path).
    context: u32 = 0,
    root: Root,
    /// The helper advertised flush-store; null = no helper to ask.
    flush_on_request: ?bool = null,
};

/// The `persistence` fact. Field names are the output schema's
/// (`mcp_tools.PERSISTENCE_SCHEMA`, drift-tested).
pub const Persistence = struct {
    identity: Identity,
    /// Survives the browser helper, this server and a reboot; null =
    /// unknown here (`reason` says why).
    durable: ?bool,
    profile: ?[]const u8 = null,
    /// The jar's directory on disk; null when nothing is written or the
    /// place is unknown.
    store: ?[]const u8 = null,
    flushed: ?Flush = null,
    /// Why `durable` is false or null; null when durable.
    reason: ?[]const u8 = null,
};

pub const GUI_REASON = "this tab lives in the user's own browser, in one of its identity containers; the GUI does not report which container or whether it persists, so this server cannot say";
pub const EPHEMERAL_REASON = "a throwaway in-memory identity: nothing is written to disk and it is destroyed with its last view";
pub const PRIVATE_REASON = "untrusted browsing keeps everything in a private root that is deleted when the browser engine stops";

/// The persistence of one identity on one engine.
pub fn derive(arena: std.mem.Allocator, f: Facts) !Persistence {
    switch (f.identity) {
        .gui => return .{ .identity = .gui, .durable = null, .reason = GUI_REASON },
        .ephemeral => return .{ .identity = .ephemeral, .durable = false, .flushed = .never, .reason = EPHEMERAL_REASON },
        .default, .named => {},
    }
    const profile: ?[]const u8 = if (f.identity == .named) f.profile else null;
    const flushed: ?Flush = if (f.flush_on_request) |b| (if (b) .periodic else .graceful_exit) else null;
    return switch (f.root) {
        .durable => |root| .{
            .identity = f.identity,
            .durable = true,
            .profile = profile,
            .store = try jarOf(arena, root, f),
            .flushed = flushed,
        },
        .instance => |in| .{
            .identity = f.identity,
            .durable = false,
            .profile = profile,
            .store = try jarOf(arena, in.path, f),
            .flushed = flushed,
            .reason = try std.fmt.allocPrint(arena, "no durable profile store ({s}): the browser keeps this jar in the MCP instance's own directory, which a temporary instance removes when the server exits and which does not outlive a logout or reboot", .{in.why}),
        },
        .private => .{ .identity = f.identity, .durable = false, .profile = profile, .flushed = .never, .reason = PRIVATE_REASON },
        .unknown => |why| .{ .identity = f.identity, .durable = null, .profile = profile, .reason = why },
    };
}

/// The text-lane line for a `Persistence`.
pub fn sentence(arena: std.mem.Allocator, p: Persistence) ![]const u8 {
    const who: []const u8 = if (p.profile) |n| try std.fmt.allocPrint(arena, "profile '{s}'", .{n}) else try std.fmt.allocPrint(arena, "the {s} identity", .{@tagName(p.identity)});
    const durable = p.durable orelse return std.fmt.allocPrint(arena, "persistence of {s} is unknown: {s}", .{ who, p.reason orelse "" });
    if (durable) return std.fmt.allocPrint(arena, "{s} is DURABLE: cookies, logins and site storage stay in {s}, {s}; session cookies are never kept", .{ who, p.store orelse "?", if (p.flushed) |f| f.describe() else "flushed as the browser engine that opens it decides" });
    return std.fmt.allocPrint(arena, "{s} is NOT durable: {s}", .{ who, p.reason orelse "" });
}

fn jarOf(arena: std.mem.Allocator, root: []const u8, f: Facts) ![]const u8 {
    if (f.identity == .default) return std.fmt.allocPrint(arena, "{s}/" ++ webprofiles.DEFAULT_JAR, .{root});
    var buf: [4096]u8 = undefined;
    return arena.dupe(u8, try webprofiles.jarPathIn(&buf, root, f.profile, f.context));
}

/// This MCP instance, as far as files are concerned.
pub const Instance = struct {
    /// The instance directory; null without one (--shared).
    dir: ?[]const u8,
    /// Removed when the server exits (`mcp-tmp-<pid>`).
    temporary: bool,
};

/// The text-lane sentence for a file that dies with the instance.
pub const DIES_WITH_INSTANCE = "is inside this server's temporary instance directory and is deleted when the server exits; name an absolute directory of your own to keep it";

/// Whether a file at `path` survives this MCP instance. Lexical: `..` is
/// resolved, symlinks are not followed.
pub fn outlivesInstance(arena: std.mem.Allocator, path: []const u8, inst: Instance) !bool {
    if (!inst.temporary) return true;
    const dir = inst.dir orelse return true;
    const p = try std.fs.path.resolvePosix(arena, &.{path});
    const d = try std.fs.path.resolvePosix(arena, &.{dir});
    if (!std.mem.startsWith(u8, p, d)) return true;
    return !(p.len == d.len or p[d.len] == '/');
}

const t = std.testing;

test "the default identity is durable exactly when its root is the store" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const on_store = try derive(a, .{ .identity = .default, .root = .{ .durable = "/s/anon" }, .flush_on_request = true });
    try t.expectEqual(true, on_store.durable.?);
    try t.expectEqualStrings("/s/anon/Default", on_store.store.?);
    try t.expectEqual(Flush.periodic, on_store.flushed.?);
    try t.expect(on_store.reason == null and on_store.profile == null);

    const held = try derive(a, .{ .identity = .default, .root = .{ .instance = .{ .path = "/rt/mcp-tmp-9/web-cache", .why = "pid 7 owns it" } } });
    try t.expectEqual(false, held.durable.?);
    try t.expectEqualStrings("/rt/mcp-tmp-9/web-cache/Default", held.store.?);
    try t.expect(held.flushed == null);
    try t.expect(std.mem.indexOf(u8, held.reason.?, "pid 7 owns it") != null);
}

test "named, ephemeral, gui, private and unknown identities" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const named = try derive(a, .{ .identity = .named, .profile = "work", .context = 3, .root = .{ .durable = "/s/anon" }, .flush_on_request = true });
    try t.expectEqualStrings("/s/anon/profile-work-3", named.store.?);
    try t.expectEqualStrings("work", named.profile.?);
    try t.expectEqual(true, named.durable.?);

    const eph = try derive(a, .{ .identity = .ephemeral, .root = .{ .durable = "/s/anon" } });
    try t.expectEqual(false, eph.durable.?);
    try t.expectEqual(Flush.never, eph.flushed.?);
    try t.expect(eph.store == null);

    const gui = try derive(a, .{ .identity = .gui, .root = .{ .durable = "/x" } });
    try t.expect(gui.durable == null and gui.flushed == null and gui.store == null);
    try t.expectEqualStrings(GUI_REASON, gui.reason.?);

    const priv = try derive(a, .{ .identity = .default, .root = .private });
    try t.expectEqual(false, priv.durable.?);
    try t.expect(priv.store == null);

    const unk = try derive(a, .{ .identity = .named, .profile = "w", .root = .{ .unknown = "adopted" } });
    try t.expect(unk.durable == null and unk.store == null and unk.flushed == null);
    try t.expectEqualStrings("adopted", unk.reason.?);
}

test "a file outlives the instance unless it sits in a temporary instance dir" {
    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const tmp: Instance = .{ .dir = "/rt/sketerm/mcp-tmp-5", .temporary = true };
    try t.expect(!try outlivesInstance(a, "/rt/sketerm/mcp-tmp-5/web-fetch/a.zip", tmp));
    try t.expect(!try outlivesInstance(a, "/rt/sketerm/mcp-tmp-5", tmp));
    try t.expect(try outlivesInstance(a, "/rt/sketerm/mcp-tmp-55/x", tmp));
    try t.expect(try outlivesInstance(a, "/home/u/out/a.md", tmp));
    try t.expect(try outlivesInstance(a, "/rt/sketerm/mcp-tmp-5/../keep/a", tmp));
    try t.expect(!try outlivesInstance(a, "/rt/x/../sketerm/mcp-tmp-5/f", tmp));
    try t.expect(try outlivesInstance(a, "/rt/sketerm/mcp-work/web-fetch/a", .{ .dir = "/rt/sketerm/mcp-work", .temporary = false }));
    try t.expect(try outlivesInstance(a, "/x", .{ .dir = null, .temporary = true }));
}
