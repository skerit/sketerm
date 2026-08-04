//! Language-server registry: which binary serves which language, what
//! LSP `languageId` a file carries, and how to find a workspace root.
//!
//! The built-in table is a fallback, not a policy: a `[lsp.<name>]`
//! config section with the same `name` replaces the entry wholesale
//! (see src/config.zig). Built-ins exist so a user who has `zls`
//! installed gets Zig support without writing any config at all.
//!
//! Nothing here spawns or probes anything — this module is pure data +
//! string matching so it can live in the GTK-free test root.

const std = @import("std");

/// One configured (or built-in) language server.
///
/// `languages` and `root_files` are comma/space separated lists rather
/// than slices-of-slices so a config section can express them on one
/// line and the whole record stays trivially arena-cloneable.
pub const Server = struct {
    /// Section name / registry key ("zls", "clangd", …).
    name: []const u8 = "",
    /// Comma-separated LSP languageIds this server handles.
    languages: []const u8 = "",
    /// Executable, looked up on PATH. Empty disables the entry.
    command: []const u8 = "",
    /// Whitespace-separated argv tail.
    args: []const u8 = "",
    /// Comma-separated marker filenames; the nearest ancestor
    /// directory containing one becomes the workspace root. Empty =
    /// the document's own directory.
    root_files: []const u8 = "",
    enabled: bool = true,

    pub fn handles(self: *const Server, language_id: []const u8) bool {
        if (!self.enabled or self.command.len == 0) return false;
        return listContains(self.languages, language_id);
    }
};

/// Built-in defaults. Deliberately short: three well-known servers
/// whose invocation has been stable for years. Everything else is a
/// two-line config section.
pub const builtins = [_]Server{
    .{
        .name = "zls",
        .languages = "zig",
        .command = "zls",
        .root_files = "build.zig,build.zig.zon,.git",
    },
    .{
        .name = "clangd",
        .languages = "c,cpp,objective-c,objective-cpp,cuda",
        .command = "clangd",
        .args = "--background-index",
        .root_files = "compile_commands.json,compile_flags.txt,.clangd,CMakeLists.txt,Makefile,.git",
    },
    .{
        .name = "rust-analyzer",
        .languages = "rust",
        .command = "rust-analyzer",
        .root_files = "Cargo.toml,rust-project.json,.git",
    },
};

/// True when `needle` appears in a comma/space separated `list`.
pub fn listContains(list: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    var it = std.mem.tokenizeAny(u8, list, ", \t");
    while (it.next()) |item| {
        if (std.ascii.eqlIgnoreCase(item, needle)) return true;
    }
    return false;
}

const ExtLang = struct { ext: []const u8, id: []const u8 };

/// Extension -> LSP `languageId`. Deliberately WIDER than the
/// tree-sitter grammar set in editor/syntax.zig: a language server is
/// useful for a file we cannot syntax-highlight, and the two lookups
/// answer different questions.
const ext_table = [_]ExtLang{
    .{ .ext = "zig", .id = "zig" },
    .{ .ext = "zon", .id = "zig" },
    .{ .ext = "c", .id = "c" },
    .{ .ext = "h", .id = "c" },
    .{ .ext = "cc", .id = "cpp" },
    .{ .ext = "cpp", .id = "cpp" },
    .{ .ext = "cxx", .id = "cpp" },
    .{ .ext = "hpp", .id = "cpp" },
    .{ .ext = "hh", .id = "cpp" },
    .{ .ext = "hxx", .id = "cpp" },
    .{ .ext = "m", .id = "objective-c" },
    .{ .ext = "mm", .id = "objective-cpp" },
    .{ .ext = "cu", .id = "cuda" },
    .{ .ext = "rs", .id = "rust" },
    .{ .ext = "py", .id = "python" },
    .{ .ext = "pyi", .id = "python" },
    .{ .ext = "go", .id = "go" },
    .{ .ext = "ts", .id = "typescript" },
    .{ .ext = "tsx", .id = "typescriptreact" },
    .{ .ext = "js", .id = "javascript" },
    .{ .ext = "jsx", .id = "javascriptreact" },
    .{ .ext = "lua", .id = "lua" },
    .{ .ext = "sh", .id = "shellscript" },
    .{ .ext = "bash", .id = "shellscript" },
    .{ .ext = "json", .id = "json" },
    .{ .ext = "jsonc", .id = "jsonc" },
    .{ .ext = "md", .id = "markdown" },
    .{ .ext = "markdown", .id = "markdown" },
    .{ .ext = "html", .id = "html" },
    .{ .ext = "css", .id = "css" },
    .{ .ext = "toml", .id = "toml" },
    .{ .ext = "yaml", .id = "yaml" },
    .{ .ext = "yml", .id = "yaml" },
};

/// LSP `languageId` for a path (or host-qualified spec). Empty string
/// means "no language id" — the file gets no server.
pub fn languageId(path: []const u8) []const u8 {
    const base = basenameOf(path);
    if (base.len == 0) return "";
    if (std.mem.eql(u8, base, "build.zig.zon")) return "zig";
    if (std.mem.eql(u8, base, "CMakeLists.txt")) return "cmake";
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    const ext = base[dot + 1 ..];
    if (ext.len == 0) return "";
    for (ext_table) |m| {
        if (std.ascii.eqlIgnoreCase(m.ext, ext)) return m.id;
    }
    return "";
}

/// Last component of a path, tolerating both separators and the
/// `host:/path` spec form (same rule as editor/syntax.zig's).
pub fn basenameOf(path: []const u8) []const u8 {
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\' or ch == ':') start = i + 1;
    }
    return path[start..];
}

/// Directory part of an absolute path ("/" for a top-level file).
pub fn dirnameOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    if (slash == 0) return "/";
    return path[0..slash];
}

/// Predicate the caller supplies so root resolution stays pure: "does
/// <dir>/<name> exist?".
pub const ExistsFn = *const fn (ctx: ?*anyopaque, dir: []const u8, name: []const u8) bool;

/// Nearest ancestor of `dir` (inclusive) holding one of `root_files`.
/// Falls back to `dir` itself — a server must always get SOME root, and
/// the document's own directory is the least surprising one.
pub fn findRoot(dir: []const u8, root_files: []const u8, exists: ExistsFn, ctx: ?*anyopaque) []const u8 {
    if (root_files.len == 0) return dir;
    var cur = dir;
    while (true) {
        var it = std.mem.tokenizeAny(u8, root_files, ", \t");
        while (it.next()) |marker| {
            if (exists(ctx, cur, marker)) return cur;
        }
        if (cur.len <= 1) break;
        const slash = std.mem.lastIndexOfScalar(u8, cur, '/') orelse break;
        cur = if (slash == 0) "/" else cur[0..slash];
    }
    return dir;
}

/// Percent-encode a filesystem path into a `file://` URI. Only the
/// characters that actually break parsers are escaped (space, `#`,
/// `?`, `%`, control bytes) — over-escaping makes URIs that some
/// servers fail to match against their own.
pub fn pathToUri(alloc: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "file://");
    for (path) |ch| {
        const safe = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '/', '-', '_', '.', '~', '!', '$', '&', '\'', '(', ')', '*', '+', ',', ';', '=', '@', ':' => true,
            else => false,
        };
        if (safe) {
            try out.append(alloc, ch);
        } else {
            var buf: [3]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "%{X:0>2}", .{ch}) catch unreachable;
            try out.appendSlice(alloc, s);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Inverse of `pathToUri`. Returns null for a non-`file:` URI (a
/// server pointing at `jdt:` or `zig-builtin:` has nothing we can
/// open, and guessing a path would open the wrong file).
pub fn uriToPath(alloc: std.mem.Allocator, uri: []const u8) std.mem.Allocator.Error!?[]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return null;
    var rest = uri["file://".len..];
    // "file://host/path" — we only serve the empty (localhost) authority.
    if (rest.len > 0 and rest[0] != '/') {
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        rest = rest[slash..];
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var i: usize = 0;
    while (i < rest.len) {
        if (rest[i] == '%' and i + 2 < rest.len) {
            const hi = std.fmt.charToDigit(rest[i + 1], 16) catch {
                try out.append(alloc, rest[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(rest[i + 2], 16) catch {
                try out.append(alloc, rest[i]);
                i += 1;
                continue;
            };
            try out.append(alloc, @intCast(hi * 16 + lo));
            i += 3;
            continue;
        }
        try out.append(alloc, rest[i]);
        i += 1;
    }
    return try out.toOwnedSlice(alloc);
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

test "servers: language ids from extensions and special basenames" {
    try testing.expectEqualStrings("zig", languageId("/src/main.zig"));
    try testing.expectEqualStrings("zig", languageId("build.zig.zon"));
    try testing.expectEqualStrings("cpp", languageId("box:/home/x/a.CPP"));
    try testing.expectEqualStrings("rust", languageId("lib.rs"));
    try testing.expectEqualStrings("", languageId("/etc/passwd"));
    try testing.expectEqualStrings("", languageId(""));
}

test "servers: builtin matching honours enabled and command" {
    try testing.expect(builtins[0].handles("zig"));
    try testing.expect(!builtins[0].handles("c"));
    try testing.expect(builtins[1].handles("cpp"));
    var off = builtins[0];
    off.enabled = false;
    try testing.expect(!off.handles("zig"));
    var noexe = builtins[0];
    noexe.command = "";
    try testing.expect(!noexe.handles("zig"));
}

test "servers: listContains ignores case and separators" {
    try testing.expect(listContains("c, cpp\tobjective-c", "CPP"));
    try testing.expect(!listContains("c,cpp", "cs"));
    try testing.expect(!listContains("", "zig"));
}

const FakeFs = struct {
    files: []const []const u8,
    fn exists(ctx: ?*anyopaque, dir: []const u8, name: []const u8) bool {
        const self: *const FakeFs = @ptrCast(@alignCast(ctx.?));
        var buf: [512]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return false;
        for (self.files) |f| {
            if (std.mem.eql(u8, f, full)) return true;
        }
        return false;
    }
};

test "servers: findRoot walks up to the nearest marker" {
    var fs = FakeFs{ .files = &.{"/home/u/proj/build.zig"} };
    const root = findRoot("/home/u/proj/src/deep", "build.zig,.git", FakeFs.exists, &fs);
    try testing.expectEqualStrings("/home/u/proj", root);
}

test "servers: findRoot falls back to the document directory" {
    var fs = FakeFs{ .files = &.{} };
    try testing.expectEqualStrings(
        "/tmp/x",
        findRoot("/tmp/x", "build.zig", FakeFs.exists, &fs),
    );
    // No markers configured = no walk at all.
    try testing.expectEqualStrings("/tmp/x", findRoot("/tmp/x", "", FakeFs.exists, &fs));
}

test "servers: findRoot terminates at the filesystem root" {
    var fs = FakeFs{ .files = &.{"//.git"} };
    // "/" + "/.git" is what the join produces at the top; the walk must
    // stop there rather than loop forever.
    const root = findRoot("/a", ".git", FakeFs.exists, &fs);
    try testing.expectEqualStrings("/", root);
}

test "servers: path <-> uri round trip with awkward characters" {
    const path = "/home/u/my proj/a#b?c%d/main.zig";
    const uri = try pathToUri(testing.allocator, path);
    defer testing.allocator.free(uri);
    try testing.expect(std.mem.startsWith(u8, uri, "file:///home/u/my%20proj/"));
    const back = (try uriToPath(testing.allocator, uri)).?;
    defer testing.allocator.free(back);
    try testing.expectEqualStrings(path, back);
}

test "servers: uriToPath refuses non-file schemes and handles the localhost authority" {
    try testing.expect((try uriToPath(testing.allocator, "jdt:/Foo")) == null);
    const p = (try uriToPath(testing.allocator, "file://localhost/x/y.zig")).?;
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("/x/y.zig", p);
}

test "servers: dirnameOf" {
    try testing.expectEqualStrings("/a/b", dirnameOf("/a/b/c.zig"));
    try testing.expectEqualStrings("/", dirnameOf("/c.zig"));
    try testing.expectEqualStrings("/", dirnameOf("c.zig"));
}
