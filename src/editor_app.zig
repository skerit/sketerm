//! GTK-free half of the `sketerm edit` entry point: which window the
//! editor opens in, and how command-line arguments become editor
//! specs. main.zig owns the GApplication side, ui/editorwin.zig the
//! widgets. Mirrors `filebrowser/entry.zig` (mode flags, --here/--tab)
//! and `viewer.zig` (batch canonicalization) — the editor is the third
//! application identity built the same way.

const std = @import("std");
const invocation = @import("util/invocation.zig");
const entry = @import("filebrowser/entry.zig");
const paths = @import("filebrowser/paths.zig");

pub const ID_SUFFIX = ".editor";
pub const APP_NAME = "Sketerm Editor";
pub const BINARY_NAME = "sketerm-editor";

/// Where `sketerm edit` puts the editor face.
pub const Mode = enum {
    /// Default: the DEDICATED editor application — its own
    /// GApplication id, taskbar icon and window list. Never touches a
    /// running terminal instance.
    window,
    /// `--here`: the invoking terminal pane itself wears the editor
    /// face. Pure IPC into the running terminal; no window of our own.
    here,
    /// `--tab`: an editor tab in the window that OWNS the invoking
    /// pane. Same IPC-only story as `--here`.
    tab,
};

/// A 1-based caret target from `--line N[:col]`.
pub const Position = struct {
    line: usize,
    col: usize = 1,
};

pub const Request = struct {
    allocator: std.mem.Allocator,
    mode: Mode = .window,
    /// Host-qualified specs, owned, in command-line order.
    specs: [][]u8 = &.{},
    /// Caret target applied to the FIRST document only: a position is
    /// a statement about one file, and silently applying it to every
    /// argument would put carets nobody asked for.
    position: ?Position = null,
    /// `--help` / `-h`: print usage and do nothing else.
    help: bool = false,

    pub fn empty(allocator: std.mem.Allocator) Request {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Request) void {
        for (self.specs) |spec| self.allocator.free(spec);
        if (self.specs.len > 0) self.allocator.free(self.specs);
        self.specs = &.{};
    }
};

/// Index of the first editor argument, or null for another entry point.
pub fn invocationStart(args: []const []const u8) ?usize {
    return invocation.start(args, BINARY_NAME, &.{ "edit", "editor" });
}

/// Parse a `--line` value: `N` or `N:col`, both 1-based. Strict —
/// garbage yields null rather than a caret at a position the user
/// never named.
pub fn parsePosition(text: []const u8) ?Position {
    if (text.len == 0) return null;
    const colon = std.mem.indexOfScalar(u8, text, ':');
    const line_text = if (colon) |at| text[0..at] else text;
    const line = std.fmt.parseInt(usize, line_text, 10) catch return null;
    if (line == 0) return null;
    if (colon == null) return .{ .line = line };
    const col = std.fmt.parseInt(usize, text[colon.? + 1 ..], 10) catch return null;
    if (col == 0) return null;
    return .{ .line = line, .col = col };
}

/// Canonicalize every positional editor argument into a host-qualified
/// spec. Relative paths resolve against `cwd` (the invoking shell's
/// directory, which GApplication hands us for forwarded invocations),
/// never against this process's own.
pub fn collect(allocator: std.mem.Allocator, args: []const []const u8, cwd: ?[]const u8) !Request {
    const start = invocationStart(args) orelse return error.NotEditorInvocation;
    var req = Request.empty(allocator);
    errdefer req.deinit();

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |spec| allocator.free(spec);
        out.deinit(allocator);
    }

    var positional = false;
    var index = start;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (!positional) {
            if (std.mem.eql(u8, arg, "--")) {
                positional = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--here")) {
                req.mode = .here;
                continue;
            }
            if (std.mem.eql(u8, arg, "--tab")) {
                req.mode = .tab;
                continue;
            }
            if (std.mem.eql(u8, arg, "--window")) {
                req.mode = .window;
                continue;
            }
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                req.help = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--line=")) {
                if (parsePosition(arg["--line=".len..])) |p| req.position = p;
                continue;
            }
            if (std.mem.eql(u8, arg, "--line")) {
                if (index + 1 < args.len) {
                    index += 1;
                    if (parsePosition(args[index])) |p| req.position = p;
                }
                continue;
            }
            // Unrecognised flags belong to the caller's own loop
            // (`sketerm edit --config x` still reaches --config).
            if (arg.len > 0 and arg[0] == '-') continue;
        }

        const normalized = try entry.normalizeArgAlloc(allocator, arg);
        defer allocator.free(normalized);
        const loc = paths.parseSpec(normalized);
        const owned = if (loc.current_host and (loc.path.len == 0 or loc.path[0] != '/')) blk: {
            const base = cwd orelse ".";
            const joined = if (std.mem.eql(u8, base, "/"))
                try std.fmt.allocPrint(allocator, "/{s}", .{loc.path})
            else
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, loc.path });
            defer allocator.free(joined);
            break :blk try paths.formatSpecAlloc(allocator, null, joined);
        } else try paths.formatSpecAlloc(allocator, loc.host, loc.path);
        try out.append(allocator, owned);
    }

    req.specs = try out.toOwnedSlice(allocator);
    return req;
}

test "editor invocation recognizes subcommand and installed alias" {
    try std.testing.expectEqual(@as(?usize, 2), invocationStart(&.{ "sketerm", "edit", "a.txt" }));
    try std.testing.expectEqual(@as(?usize, 2), invocationStart(&.{ "sketerm", "editor" }));
    try std.testing.expectEqual(@as(?usize, 1), invocationStart(&.{ "/usr/bin/sketerm-editor", "a.txt" }));
    try std.testing.expect(invocationStart(&.{ "sketerm", "files" }) == null);
    try std.testing.expect(invocationStart(&.{ "sketerm", "view" }) == null);
    // Only the exact basename counts.
    try std.testing.expect(invocationStart(&.{"/usr/bin/sketerm-editor-extra"}) == null);
    try std.testing.expect(invocationStart(&.{"sketerm"}) == null);
}

test "editor position parsing is strict and 1-based" {
    try std.testing.expectEqual(@as(usize, 5), parsePosition("5").?.line);
    try std.testing.expectEqual(@as(usize, 1), parsePosition("5").?.col);
    const both = parsePosition("12:7").?;
    try std.testing.expectEqual(@as(usize, 12), both.line);
    try std.testing.expectEqual(@as(usize, 7), both.col);
    try std.testing.expect(parsePosition("0") == null);
    try std.testing.expect(parsePosition("3:0") == null);
    try std.testing.expect(parsePosition("3:abc") == null);
    try std.testing.expect(parsePosition("") == null);
    try std.testing.expect(parsePosition("x") == null);
}

test "editor batch canonicalizes local URI relative and remote resources" {
    const a = std.testing.allocator;
    var req = try collect(a, &.{
        "sketerm",
        "edit",
        "file:///tmp/a%20b.txt",
        "relative.zig",
        "user@box:/etc/hosts",
    }, "/work");
    defer req.deinit();
    try std.testing.expectEqual(Mode.window, req.mode);
    try std.testing.expectEqual(@as(usize, 3), req.specs.len);
    try std.testing.expectEqualStrings("local:/tmp/a b.txt", req.specs[0]);
    try std.testing.expectEqualStrings("local:/work/relative.zig", req.specs[1]);
    try std.testing.expectEqualStrings("user@box:/etc/hosts", req.specs[2]);
    try std.testing.expect(req.position == null);
}

test "editor mode flags, line option and help" {
    const a = std.testing.allocator;
    var here = try collect(a, &.{ "sketerm", "edit", "--here", "--line", "5:3", "/srv/x.txt" }, "/work");
    defer here.deinit();
    try std.testing.expectEqual(Mode.here, here.mode);
    try std.testing.expectEqual(@as(usize, 5), here.position.?.line);
    try std.testing.expectEqual(@as(usize, 3), here.position.?.col);
    try std.testing.expectEqual(@as(usize, 1), here.specs.len);
    try std.testing.expectEqualStrings("local:/srv/x.txt", here.specs[0]);

    var tab = try collect(a, &.{ "sketerm-editor", "--tab", "--line=9" }, "/work");
    defer tab.deinit();
    try std.testing.expectEqual(Mode.tab, tab.mode);
    try std.testing.expectEqual(@as(usize, 9), tab.position.?.line);
    try std.testing.expectEqual(@as(usize, 0), tab.specs.len);

    var help = try collect(a, &.{ "sketerm", "edit", "--here", "--help" }, null);
    defer help.deinit();
    try std.testing.expect(help.help);

    // --window is the explicit spelling of the default.
    var win = try collect(a, &.{ "sketerm", "edit", "--window" }, null);
    defer win.deinit();
    try std.testing.expectEqual(Mode.window, win.mode);
}

test "editor treats flag-shaped names after the option terminator as files" {
    const a = std.testing.allocator;
    var req = try collect(a, &.{ "sketerm-editor", "--", "--line", "-h" }, "/work");
    defer req.deinit();
    try std.testing.expectEqual(@as(usize, 2), req.specs.len);
    try std.testing.expectEqualStrings("local:/work/--line", req.specs[0]);
    try std.testing.expectEqualStrings("local:/work/-h", req.specs[1]);
    try std.testing.expect(req.position == null);
    try std.testing.expect(!req.help);
}

test "editor keeps a long remote path intact" {
    const a = std.testing.allocator;
    const path = try a.alloc(u8, paths.SPEC_BUF_LEN + 32);
    defer a.free(path);
    path[0] = '/';
    @memset(path[1..], 'r');
    const arg = try std.fmt.allocPrint(a, "user@host:{s}", .{path});
    defer a.free(arg);
    var req = try collect(a, &.{ "sketerm-editor", arg }, null);
    defer req.deinit();
    try std.testing.expectEqual(@as(usize, 1), req.specs.len);
    try std.testing.expectEqualStrings(arg, req.specs[0]);
}

test "editor rejects a non-editor invocation" {
    try std.testing.expectError(
        error.NotEditorInvocation,
        collect(std.testing.allocator, &.{ "sketerm", "--restore" }, null),
    );
}
