//! Project/workspace model: which root a document belongs to.
//!
//! ## The model, in one paragraph
//!
//! A project is a `(host, root)` pair discovered by walking UP from a
//! document's directory to the nearest ancestor holding a marker file.
//! Discovery reuses `lsp/servers.zig`'s `findRoot` machinery rather
//! than inventing a second scheme — the only difference is the marker
//! LIST (a superset: every VCS directory plus the language markers the
//! built-in servers already name) and the fact that a miss answers
//! `null` instead of falling back to the document's own directory. A
//! loose file with no marker above it therefore has NO project, and
//! every project-aware feature stays switched off for it: that is what
//! keeps single-file editing exactly as cheap as it was.
//!
//! ## Several documents, several roots
//!
//! An editor face holds a `Set`: as many projects as its open tabs
//! need, deduplicated by `(host, root)`. Each tab is associated with at
//! most ONE project — the one its own path resolves to — so a window
//! showing files from three repositories has three projects and no
//! ambiguity about which is "the" project. Everything that needs a
//! single root (project-wide search, the git gutter) uses the ACTIVE
//! tab's project, so the answer follows the document the user is
//! looking at. Projects are refcounted by their tabs and dropped when
//! the last one closes.
//!
//! ## Relationship to the LSP session root
//!
//! Deliberately separate. A language server picks its root from its own
//! `root_files` (`[lsp.<name>] root_files`), because a server's notion
//! of a workspace is narrower and server-specific: clangd wants the
//! directory with `compile_commands.json`, which may be a build
//! subdirectory, and rust-analyzer wants the crate. The two normally
//! coincide (both walk up to `.git`), and when they do not, the project
//! is the user's unit and the LSP root is the server's. Nothing here
//! feeds `attachTab`; `Project.lspRootHint` exists only so a UI can say
//! which is which.
//!
//! GTK-free: pure data plus an injected `exists` predicate, so the
//! whole thing is testable with a fake filesystem and lives in both
//! test roots.

const std = @import("std");
const servers = @import("../lsp/servers.zig");
const paths = @import("../filebrowser/paths.zig");

/// Marker files that define a project root, in no particular order —
/// the walk takes the NEAREST ancestor holding any of them, so the
/// order in this list never decides anything.
///
/// Superset of the `root_files` lists in `lsp/servers.zig`: the VCS
/// directories first (a repository is a project even in a language we
/// cannot serve), then the language markers.
pub const default_markers =
    ".git,.hg,.svn,.jj," ++
    "build.zig,build.zig.zon," ++
    "Cargo.toml,rust-project.json," ++
    "package.json,deno.json,tsconfig.json," ++
    "go.mod," ++
    "pyproject.toml,setup.py,setup.cfg," ++
    "CMakeLists.txt,compile_commands.json,compile_flags.txt,Makefile,meson.build," ++
    "pom.xml,build.gradle,composer.json,Gemfile,mix.exs,dune-project," ++
    ".sketerm-project";

/// Markers that make the root a version-controlled checkout. The git
/// gutter needs one of these; everything else works either way.
pub const vcs_markers = ".git,.hg,.svn,.jj";

/// Injected filesystem predicate, same shape as `servers.ExistsFn`, so
/// a caller that already has one for LSP root resolution reuses it.
pub const ExistsFn = servers.ExistsFn;

/// One discovered root. Slices point into the caller's `spec` or into
/// `default_markers`; `Set` is what owns copies.
pub const Found = struct {
    /// Host part of the spec ("" = local).
    host: []const u8 = "",
    /// Absolute directory of the project root.
    root: []const u8,
    /// The marker that stopped the walk.
    marker: []const u8,

    pub fn isVcs(self: Found) bool {
        return servers.listContains(vcs_markers, self.marker);
    }
};

/// Nearest ancestor of the document's directory holding a marker, or
/// null when there is none.
///
/// `markers` empty means "use the built-ins". A caller that wants no
/// discovery at all passes `.{}` and never calls this.
pub fn discover(spec: []const u8, markers: []const u8, exists: ExistsFn, ctx: ?*anyopaque) ?Found {
    const list = if (markers.len == 0) default_markers else markers;
    const loc = paths.parseSpec(spec);
    if (loc.path.len == 0 or loc.path[0] != '/') return null;
    const dir = servers.dirnameOf(loc.path);
    var cur = dir;
    while (true) {
        var it = std.mem.tokenizeAny(u8, list, ", \t");
        while (it.next()) |marker| {
            if (exists(ctx, cur, marker)) {
                return .{
                    .host = loc.host orelse "",
                    .root = cur,
                    .marker = marker,
                };
            }
        }
        if (cur.len <= 1) return null;
        const slash = std.mem.lastIndexOfScalar(u8, cur, '/') orelse return null;
        cur = if (slash == 0) "/" else cur[0..slash];
    }
}

/// Last path component of a root spec — the label a UI shows for a
/// project it has only the root of (a layout restore, before the
/// re-derivation lands).
pub fn labelOf(root_spec: []const u8) []const u8 {
    const path = paths.parseSpec(root_spec).path;
    if (path.len <= 1) return path;
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return if (slash + 1 >= path.len) path else path[slash + 1 ..];
}

/// A project the editor face is holding open. Owned strings; created
/// and destroyed only through `Set`.
pub const Project = struct {
    /// "" = local, "user@box" = the same host string the editor's file
    /// specs carry.
    host: []u8,
    /// Absolute root directory ON `host`.
    root: []u8,
    /// The marker that identified it ("build.zig", ".git", …). Owned.
    marker: []u8,
    /// Tabs currently associated. The `Set` drops the project at zero.
    refs: u32 = 0,

    /// Last component of `root` — what a UI shows.
    pub fn label(self: *const Project) []const u8 {
        if (self.root.len <= 1) return self.root;
        const slash = std.mem.lastIndexOfScalar(u8, self.root, '/') orelse return self.root;
        return if (slash + 1 >= self.root.len) self.root else self.root[slash + 1 ..];
    }

    pub fn isVcs(self: *const Project) bool {
        return servers.listContains(vcs_markers, self.marker);
    }

    /// Host-qualified spec of the root, written into `buf`.
    pub fn rootSpec(self: *const Project, buf: []u8) []const u8 {
        return paths.formatSpec(buf, if (self.host.len == 0) null else self.host, self.root);
    }

    /// True when `spec` names a file at or under this root ON this host.
    pub fn contains(self: *const Project, spec: []const u8) bool {
        const loc = paths.parseSpec(spec);
        const h = loc.host orelse "";
        if (!std.mem.eql(u8, h, self.host)) return false;
        if (!std.mem.startsWith(u8, loc.path, self.root)) return false;
        if (loc.path.len == self.root.len) return true;
        return self.root.len <= 1 or loc.path[self.root.len] == '/';
    }

    /// Path of `spec` relative to the root ("" when it is the root, the
    /// absolute path back when it is outside).
    pub fn relative(self: *const Project, spec: []const u8) []const u8 {
        const loc = paths.parseSpec(spec);
        if (!self.contains(spec)) return loc.path;
        if (loc.path.len <= self.root.len) return "";
        const skip: usize = if (self.root.len <= 1) 1 else self.root.len + 1;
        return loc.path[@min(skip, loc.path.len)..];
    }

    /// What the LSP client would pick for this document, for a UI that
    /// wants to explain the difference. Never used to configure a
    /// server — `editorlsp.Manager` resolves its own root.
    pub fn lspRootHint(
        self: *const Project,
        doc_spec: []const u8,
        root_files: []const u8,
        exists: ExistsFn,
        ctx: ?*anyopaque,
    ) []const u8 {
        const loc = paths.parseSpec(doc_spec);
        if (loc.path.len == 0) return self.root;
        return servers.findRoot(servers.dirnameOf(loc.path), root_files, exists, ctx);
    }
};

/// Every project an editor face is holding, deduplicated by
/// `(host, root)`.
pub const Set = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(*Project) = .empty,
    /// Marker list in force (borrowed; the caller owns it and must keep
    /// it alive, or leave it empty for the built-ins).
    markers: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator) Set {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Set) void {
        for (self.items.items) |p| self.free(p);
        self.items.deinit(self.allocator);
        self.items = .empty;
    }

    fn free(self: *Set, p: *Project) void {
        self.allocator.free(p.host);
        self.allocator.free(p.root);
        self.allocator.free(p.marker);
        self.allocator.destroy(p);
    }

    pub fn find(self: *Set, host: []const u8, root: []const u8) ?*Project {
        for (self.items.items) |p| {
            if (std.mem.eql(u8, p.host, host) and std.mem.eql(u8, p.root, root)) return p;
        }
        return null;
    }

    /// Discover (or reuse) the project for `spec` and take a reference.
    /// Null = the document has no project, which is not an error.
    pub fn acquire(self: *Set, spec: []const u8, exists: ExistsFn, ctx: ?*anyopaque) ?*Project {
        const found = discover(spec, self.markers, exists, ctx) orelse return null;
        if (self.find(found.host, found.root)) |p| {
            p.refs += 1;
            return p;
        }
        const p = self.allocator.create(Project) catch return null;
        const host = self.allocator.dupe(u8, found.host) catch {
            self.allocator.destroy(p);
            return null;
        };
        const root = self.allocator.dupe(u8, found.root) catch {
            self.allocator.free(host);
            self.allocator.destroy(p);
            return null;
        };
        const marker = self.allocator.dupe(u8, found.marker) catch {
            self.allocator.free(host);
            self.allocator.free(root);
            self.allocator.destroy(p);
            return null;
        };
        p.* = .{ .host = host, .root = root, .marker = marker, .refs = 1 };
        self.items.append(self.allocator, p) catch {
            self.free(p);
            return null;
        };
        return p;
    }

    /// Drop one tab's reference. The project dies at zero.
    pub fn release(self: *Set, project: ?*Project) void {
        const p = project orelse return;
        if (p.refs > 0) p.refs -= 1;
        if (p.refs > 0) return;
        for (self.items.items, 0..) |q, i| {
            if (q == p) {
                _ = self.items.orderedRemove(i);
                break;
            }
        }
        self.free(p);
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

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

test "project: discovery walks up to the nearest marker" {
    var fs = FakeFs{ .files = &.{"/home/u/proj/build.zig"} };
    const f = discover("/home/u/proj/src/deep/main.zig", "", FakeFs.exists, &fs).?;
    try testing.expectEqualStrings("/home/u/proj", f.root);
    try testing.expectEqualStrings("build.zig", f.marker);
    try testing.expectEqualStrings("", f.host);
    try testing.expect(!f.isVcs());
}

test "project: nearest marker wins over a further VCS root" {
    var fs = FakeFs{ .files = &.{ "/w/.git", "/w/sub/package.json" } };
    const f = discover("/w/sub/a/b.js", "", FakeFs.exists, &fs).?;
    try testing.expectEqualStrings("/w/sub", f.root);
    try testing.expectEqualStrings("package.json", f.marker);
}

test "project: a loose file has no project at all" {
    var fs = FakeFs{ .files = &.{} };
    try testing.expect(discover("/tmp/scratch.txt", "", FakeFs.exists, &fs) == null);
    // Relative or empty specs never resolve.
    try testing.expect(discover("notes.txt", "", FakeFs.exists, &fs) == null);
    try testing.expect(discover("", "", FakeFs.exists, &fs) == null);
}

test "project: a remote spec keeps its host" {
    var fs = FakeFs{ .files = &.{"/srv/app/.git"} };
    const f = discover("box:/srv/app/src/x.c", "", FakeFs.exists, &fs).?;
    try testing.expectEqualStrings("box", f.host);
    try testing.expectEqualStrings("/srv/app", f.root);
    try testing.expect(f.isVcs());
}

test "project: a custom marker list replaces the built-ins" {
    var fs = FakeFs{ .files = &.{ "/a/.git", "/a/b/OWNERS" } };
    const f = discover("/a/b/c.txt", "OWNERS", FakeFs.exists, &fs).?;
    try testing.expectEqualStrings("/a/b", f.root);
    // ".git" is not in the custom list, so a file with only that above
    // it has no project.
    try testing.expect(discover("/a/d.txt", "OWNERS", FakeFs.exists, &fs) == null);
}

test "project: discovery terminates at the filesystem root" {
    var fs = FakeFs{ .files = &.{"//.git"} };
    const f = discover("/a.zig", "", FakeFs.exists, &fs).?;
    try testing.expectEqualStrings("/", f.root);
}

test "project: set deduplicates and refcounts" {
    var fs = FakeFs{ .files = &.{"/w/.git"} };
    var set = Set.init(testing.allocator);
    defer set.deinit();

    const a = set.acquire("/w/a.zig", FakeFs.exists, &fs).?;
    const b = set.acquire("/w/sub/b.zig", FakeFs.exists, &fs).?;
    try testing.expectEqual(a, b);
    try testing.expectEqual(@as(usize, 1), set.items.items.len);
    try testing.expectEqual(@as(u32, 2), a.refs);
    try testing.expectEqualStrings("w", a.label());

    set.release(a);
    try testing.expectEqual(@as(usize, 1), set.items.items.len);
    set.release(b);
    try testing.expectEqual(@as(usize, 0), set.items.items.len);
}

test "project: two roots coexist in one set" {
    var fs = FakeFs{ .files = &.{ "/one/.git", "/two/Cargo.toml" } };
    var set = Set.init(testing.allocator);
    defer set.deinit();
    _ = set.acquire("/one/x.zig", FakeFs.exists, &fs).?;
    _ = set.acquire("/two/src/lib.rs", FakeFs.exists, &fs).?;
    try testing.expectEqual(@as(usize, 2), set.items.items.len);
}

test "project: the same root on two hosts is two projects" {
    var fs = FakeFs{ .files = &.{"/w/.git"} };
    var set = Set.init(testing.allocator);
    defer set.deinit();
    const local = set.acquire("/w/a.zig", FakeFs.exists, &fs).?;
    const remote = set.acquire("box:/w/a.zig", FakeFs.exists, &fs).?;
    try testing.expect(local != remote);
    try testing.expectEqual(@as(usize, 2), set.items.items.len);
}

test "project: contains and relative respect the host and the boundary" {
    var fs = FakeFs{ .files = &.{"/w/.git"} };
    var set = Set.init(testing.allocator);
    defer set.deinit();
    const p = set.acquire("/w/a.zig", FakeFs.exists, &fs).?;
    try testing.expect(p.contains("/w/a.zig"));
    try testing.expect(p.contains("/w/src/b.zig"));
    try testing.expect(!p.contains("/works/a.zig"));
    try testing.expect(!p.contains("box:/w/a.zig"));
    try testing.expectEqualStrings("src/b.zig", p.relative("/w/src/b.zig"));
    try testing.expectEqualStrings("", p.relative("/w"));
    try testing.expectEqualStrings("/elsewhere/c.zig", p.relative("/elsewhere/c.zig"));
}

test "project: labelOf names a root spec" {
    try testing.expectEqualStrings("proj", labelOf("/home/u/proj"));
    try testing.expectEqualStrings("proj", labelOf("box:/srv/proj"));
    try testing.expectEqualStrings("/", labelOf("/"));
}

test "project: rootSpec round-trips the host" {
    var fs = FakeFs{ .files = &.{"/srv/.git"} };
    var set = Set.init(testing.allocator);
    defer set.deinit();
    const p = set.acquire("box:/srv/x.c", FakeFs.exists, &fs).?;
    var buf: [paths.SPEC_BUF_LEN]u8 = undefined;
    try testing.expectEqualStrings("box:/srv", p.rootSpec(&buf));
}

test "project: lspRootHint answers the server's own walk" {
    // ".clangd" is a server marker and NOT a project marker, so the two
    // walks land in different places -- which is the whole point.
    var fs = FakeFs{ .files = &.{ "/w/.git", "/w/build/.clangd" } };
    var set = Set.init(testing.allocator);
    defer set.deinit();
    const p = set.acquire("/w/build/gen/x.c", FakeFs.exists, &fs).?;
    try testing.expectEqualStrings("/w", p.root);
    try testing.expectEqualStrings(
        "/w/build",
        p.lspRootHint("/w/build/gen/x.c", ".clangd,.git", FakeFs.exists, &fs),
    );
}
