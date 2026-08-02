//! GTK-free half of the `sketerm files` entry point: which window the
//! browser opens in, and how a command-line location argument becomes
//! a browser spec. main.zig owns the GApplication side, window.zig the
//! widgets.

const std = @import("std");
const c = @import("../c.zig").c;
const paths = @import("paths.zig");

/// Where `sketerm files` puts the browser face.
pub const Mode = enum {
    /// Default: the DEDICATED file-manager application -- its own
    /// GApplication id, its own taskbar icon and window list. Never
    /// touches a running terminal instance.
    window,
    /// `--here`: the invoking terminal pane itself becomes the browser.
    /// Pure IPC into the running terminal instance; no window of our
    /// own, no second app identity.
    here,
    /// `--tab`: a browser tab in the window that OWNS the invoking
    /// terminal pane. Same IPC-only story as `--here`.
    tab,
};

pub const Request = struct {
    mode: Mode = .window,
    /// Explicit start location (path, spec or file:// URI); null =
    /// derive it from the invoking pane.
    spec: ?[]const u8 = null,
    /// `--help` / `-h` after the subcommand: print the usage text and
    /// do nothing else, whatever the mode says.
    help: bool = false,
};

/// Parse a `sketerm files ...` invocation out of a full argv (argv[0]
/// included). Returns null when this is not a files invocation. Tokens
/// we do not recognise are left for the caller's own flag loop, so
/// `sketerm files --no-save` still reaches --no-save.
pub fn parse(args: []const []const u8) ?Request {
    var req: Request = .{};
    var found = false;
    for (args, 0..) |a, i| {
        if (!found) {
            // argv[0] is the program name; a later bare `files` opens
            // the subcommand, so a directory named "files" can still be
            // passed as the spec after it. A binary NAMED sketerm-files
            // is the subcommand itself: the distinct executable exists
            // so taskbars that match windows by process cannot merge
            // the file manager with the terminal.
            if (i == 0 and invokedAsFiles(a)) {
                found = true;
            } else if (i > 0 and std.mem.eql(u8, a, "files")) {
                found = true;
            }
            continue;
        }
        if (std.mem.eql(u8, a, "--here")) {
            req.mode = .here;
        } else if (std.mem.eql(u8, a, "--tab")) {
            req.mode = .tab;
        } else if (std.mem.eql(u8, a, "--window")) {
            req.mode = .window;
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            req.help = true;
        } else if (req.spec == null and a.len > 0 and a[0] != '-') {
            req.spec = a;
        }
    }
    if (!found) return null;
    return req;
}

/// True when argv[0] names the dedicated file-manager binary.
fn invokedAsFiles(argv0: []const u8) bool {
    const base = if (std.mem.lastIndexOfScalar(u8, argv0, '/')) |s|
        argv0[s + 1 ..]
    else
        argv0;
    return std.mem.eql(u8, base, "sketerm-files");
}

/// Host-qualified start location for a browser opened from a pane
/// whose shell last reported `cwd` on `host` (null host = local). A
/// remote pane's cwd is a path on ITS host, so handing the bare path
/// to the browser would open a local directory that usually does not
/// exist. A remote pane with no reported cwd opens its own root rather
/// than silently falling back to the local browser.
pub fn startSpec(buf: []u8, host: ?[]const u8, cwd: ?[]const u8) ?[]const u8 {
    const p = cwd orelse if (host != null) "/" else return null;
    if (p.len == 0) return if (host != null) paths.formatSpec(buf, host, "/") else null;
    return paths.formatSpec(buf, host, p);
}

/// Decode one percent-escape; null when `s` does not start with a
/// well-formed one.
fn pctByte(s: []const u8) ?u8 {
    if (s.len < 3 or s[0] != '%') return null;
    const hi = std.fmt.charToDigit(s[1], 16) catch return null;
    const lo = std.fmt.charToDigit(s[2], 16) catch return null;
    return hi * 16 + lo;
}

/// Turn a command-line location argument into a spec `paths.parseSpec`
/// understands. A `file://` URI is percent-decoded (the desktop entry
/// hands us URIs via %U); a non-empty, non-localhost authority becomes
/// our own host prefix, since that is the only meaning this program
/// has for "this path on that machine". Everything else passes through
/// untouched, so plain paths and `user@box:/path` specs are unaffected.
/// The result is a slice of `buf` only when decoding was needed.
pub fn normalizeArg(buf: []u8, arg: []const u8) []const u8 {
    const scheme = "file://";
    if (!std.ascii.startsWithIgnoreCase(arg, scheme)) return arg;
    const rest = arg[scheme.len..];
    // Authority ends at the first '/', which also starts the path.
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return arg;
    const authority = rest[0..slash];
    const raw_path = rest[slash..];

    var decoded: [4096]u8 = undefined;
    var w: usize = 0;
    var i: usize = 0;
    while (i < raw_path.len and w < decoded.len) {
        if (pctByte(raw_path[i..])) |b| {
            decoded[w] = b;
            w += 1;
            i += 3;
        } else {
            decoded[w] = raw_path[i];
            w += 1;
            i += 1;
        }
    }
    const path = decoded[0..w];
    if (authority.len == 0 or std.ascii.eqlIgnoreCase(authority, "localhost"))
        return paths.formatSpec(buf, null, path);
    return paths.formatSpec(buf, authority, path);
}

/// Allocate the normalized command-line resource without truncating long URIs.
pub fn normalizeArgAlloc(allocator: std.mem.Allocator, arg: []const u8) ![]u8 {
    const scheme = "file://";
    if (!std.ascii.startsWithIgnoreCase(arg, scheme)) return allocator.dupe(u8, arg);
    const rest = arg[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return allocator.dupe(u8, arg);
    const authority = rest[0..slash];
    const raw_path = rest[slash..];
    const decoded = try allocator.alloc(u8, raw_path.len);
    defer allocator.free(decoded);
    var w: usize = 0;
    var i: usize = 0;
    while (i < raw_path.len) {
        if (pctByte(raw_path[i..])) |b| {
            decoded[w] = b;
            w += 1;
            i += 3;
        } else {
            decoded[w] = raw_path[i];
            w += 1;
            i += 1;
        }
    }
    const host: ?[]const u8 = if (authority.len == 0 or std.ascii.eqlIgnoreCase(authority, "localhost")) null else authority;
    return paths.formatSpecAlloc(allocator, host, decoded[0..w]);
}

/// A file manager registered for `inode/directory` can still be handed
/// a FILE (drag onto the launcher, "Open With"). Browsing then starts
/// in the file's PARENT directory -- the start location cannot express
/// "and select this entry", so the file itself is dropped rather than
/// listed as a directory that isn't one. Only LOCAL specs are probed:
/// a remote host's file is that host's business, and stat'ing it here
/// would answer about the wrong machine.
pub fn parentIfFile(buf: []u8, spec: []const u8) []const u8 {
    const loc = paths.parseSpec(spec);
    if (loc.host != null) return spec;
    if (loc.path.len == 0 or loc.path[0] != '/') return spec;
    var z: [4096]u8 = undefined;
    if (loc.path.len >= z.len) return spec;
    @memcpy(z[0..loc.path.len], loc.path);
    z[loc.path.len] = 0;
    var st: c.struct_stat = undefined;
    if (c.stat(@ptrCast(&z), &st) != 0) return spec;
    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) return spec;
    const slash = std.mem.lastIndexOfScalar(u8, loc.path, '/') orelse return spec;
    const parent = if (slash == 0) "/" else loc.path[0..slash];
    return paths.formatSpec(buf, null, parent);
}

/// The full command-line-argument -> browser-spec pipeline: file:// URI
/// decode, then file-to-parent. The result is always a slice of `buf`
/// (both steps may return slices of their own scratch), so `buf` must
/// outlive it.
pub fn startLocation(buf: []u8, arg: []const u8) []const u8 {
    var uri_buf: [paths.SPEC_BUF_LEN]u8 = undefined;
    var dir_buf: [paths.SPEC_BUF_LEN]u8 = undefined;
    const normalized = normalizeArg(&uri_buf, arg);
    const resolved = parentIfFile(&dir_buf, normalized);
    if (resolved.len > buf.len) return arg;
    @memcpy(buf[0..resolved.len], resolved);
    return buf[0..resolved.len];
}

test "files entry: no files token" {
    try std.testing.expect(parse(&.{ "sketerm", "--restore" }) == null);
    // argv[0] is never the subcommand.
    try std.testing.expect(parse(&.{"files"}) == null);
}

test "normalizeArgAlloc does not truncate long file URIs" {
    const a = std.testing.allocator;
    const suffix = try a.alloc(u8, paths.SPEC_BUF_LEN + 64);
    defer a.free(suffix);
    @memset(suffix, 'x');
    const uri = try std.fmt.allocPrint(a, "file:///tmp/{s}%20end.png", .{suffix});
    defer a.free(uri);
    const normalized = try normalizeArgAlloc(a, uri);
    defer a.free(normalized);
    try std.testing.expect(std.mem.startsWith(u8, normalized, "local:/tmp/"));
    try std.testing.expect(std.mem.endsWith(u8, normalized, "x end.png"));
    try std.testing.expect(normalized.len > paths.SPEC_BUF_LEN);
}

test "files entry: bare invocation defaults to the dedicated window" {
    const req = parse(&.{ "sketerm", "files" }).?;
    try std.testing.expectEqual(Mode.window, req.mode);
    try std.testing.expect(req.spec == null);
    try std.testing.expect(!req.help);
}

test "files entry: mode flags and spec" {
    const here = parse(&.{ "sketerm", "files", "--here" }).?;
    try std.testing.expectEqual(Mode.here, here.mode);

    const tab = parse(&.{ "sketerm", "files", "--tab", "/srv" }).?;
    try std.testing.expectEqual(Mode.tab, tab.mode);
    try std.testing.expectEqualStrings("/srv", tab.spec.?);

    // Spec before the flag parses the same way.
    const both = parse(&.{ "sketerm", "files", "udp:box:/var", "--here" }).?;
    try std.testing.expectEqual(Mode.here, both.mode);
    try std.testing.expectEqualStrings("udp:box:/var", both.spec.?);

    // --window is the explicit spelling of the default.
    try std.testing.expectEqual(Mode.window, parse(&.{ "sketerm", "files", "--window" }).?.mode);
}

test "files entry: a directory named files is a spec, not a second subcommand" {
    const req = parse(&.{ "sketerm", "files", "files" }).?;
    try std.testing.expectEqualStrings("files", req.spec.?);
}

test "files entry: the sketerm-files binary name IS the subcommand" {
    const bare = parse(&.{"/usr/bin/sketerm-files"}).?;
    try std.testing.expectEqual(Mode.window, bare.mode);
    try std.testing.expect(bare.spec == null);

    const spec = parse(&.{ "sketerm-files", "/srv" }).?;
    try std.testing.expectEqualStrings("/srv", spec.spec.?);

    // A dir named "files" after the binary name is a spec, never a
    // second subcommand token.
    const dir = parse(&.{ "sketerm-files", "files" }).?;
    try std.testing.expectEqualStrings("files", dir.spec.?);

    // Only the exact basename counts.
    try std.testing.expect(parse(&.{"/usr/bin/sketerm-files-extra"}) == null);
    try std.testing.expect(parse(&.{"sketerm"}) == null);
}

test "files entry: help wins over the mode" {
    const req = parse(&.{ "sketerm", "files", "--here", "--help" }).?;
    try std.testing.expect(req.help);
}

test "files entry: unknown flags are left for the caller" {
    const req = parse(&.{ "sketerm", "files", "--no-save" }).?;
    try std.testing.expect(req.spec == null);
    try std.testing.expectEqual(Mode.window, req.mode);
}

test "files entry: startSpec host-qualifies a pane cwd" {
    var buf: [paths.SPEC_BUF_LEN]u8 = undefined;
    try std.testing.expect(startSpec(&buf, null, null) == null);
    try std.testing.expect(startSpec(&buf, null, "") == null);
    try std.testing.expectEqualStrings("dalaran:/", startSpec(&buf, "dalaran", null).?);
    try std.testing.expectEqualStrings("dalaran:/", startSpec(&buf, "dalaran", "").?);

    // Local: "local:" prefix so a round trip never picks up the
    // browser tab's current host.
    const local = startSpec(&buf, null, "/home/me").?;
    try std.testing.expectEqualStrings("local:/home/me", local);
    const local_loc = paths.parseSpec(local);
    try std.testing.expect(local_loc.host == null);
    try std.testing.expect(!local_loc.current_host);
    try std.testing.expectEqualStrings("/home/me", local_loc.path);

    // SSH host.
    const ssh = startSpec(&buf, "me@box", "/srv/app").?;
    try std.testing.expectEqualStrings("me@box:/srv/app", ssh);
    const ssh_loc = paths.parseSpec(ssh);
    try std.testing.expectEqualStrings("me@box", ssh_loc.host.?);
    try std.testing.expectEqualStrings("/srv/app", ssh_loc.path);

    // UDP transport prefix survives the round trip (the ':' inside the
    // host must not split the spec).
    const udp = startSpec(&buf, "udp:box", "/var/log").?;
    try std.testing.expectEqualStrings("udp:box:/var/log", udp);
    const udp_loc = paths.parseSpec(udp);
    try std.testing.expectEqualStrings("udp:box", udp_loc.host.?);
    try std.testing.expectEqualStrings("/var/log", udp_loc.path);
}

test "files entry: file:// URIs decode to local specs" {
    var buf: [paths.SPEC_BUF_LEN]u8 = undefined;
    try std.testing.expectEqualStrings("local:/tmp", normalizeArg(&buf, "file:///tmp"));
    // Percent escapes, including a literal '%'.
    try std.testing.expectEqualStrings("local:/tmp/my dir", normalizeArg(&buf, "file:///tmp/my%20dir"));
    try std.testing.expectEqualStrings("local:/tmp/100%", normalizeArg(&buf, "file:///tmp/100%25"));
    // A malformed escape is kept verbatim rather than dropped.
    try std.testing.expectEqualStrings("local:/tmp/50%zz", normalizeArg(&buf, "file:///tmp/50%zz"));
    // localhost authority is still this machine; scheme case is free.
    try std.testing.expectEqualStrings("local:/etc", normalizeArg(&buf, "file://localhost/etc"));
    try std.testing.expectEqualStrings("local:/etc", normalizeArg(&buf, "FILE:///etc"));
    // Any other authority is a host in our own spec convention.
    try std.testing.expectEqualStrings("box:/srv", normalizeArg(&buf, "file://box/srv"));
    // Non-URI arguments pass through untouched.
    try std.testing.expectEqualStrings("/tmp", normalizeArg(&buf, "/tmp"));
    try std.testing.expectEqualStrings("me@box:/srv", normalizeArg(&buf, "me@box:/srv"));
    // No path at all: nothing to decode, leave it to parseSpec.
    try std.testing.expectEqualStrings("file://", normalizeArg(&buf, "file://"));
}

test "files entry: a file argument starts in its parent directory" {
    var buf: [paths.SPEC_BUF_LEN]u8 = undefined;

    // Directories and missing paths are left alone.
    try std.testing.expectEqualStrings("local:/tmp", parentIfFile(&buf, "local:/tmp"));
    try std.testing.expectEqualStrings("/tmp/nope-does-not-exist", parentIfFile(&buf, "/tmp/nope-does-not-exist"));
    // A remote spec is never stat'ed locally.
    try std.testing.expectEqualStrings("box:/etc/hosts", parentIfFile(&buf, "box:/etc/hosts"));

    // A real regular file resolves to its directory.
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/sketerm-entry-test-{d}", .{c.getpid()});
    const f = c.fopen(name.ptr, "wb") orelse return error.SkipZigTest;
    _ = c.fclose(f);
    defer _ = c.unlink(name.ptr);
    try std.testing.expectEqualStrings("local:/tmp", parentIfFile(&buf, name));

    // The whole pipeline: a file:// URI naming a file, with a space.
    var sp_buf: [128]u8 = undefined;
    const sp_name = try std.fmt.bufPrintZ(&sp_buf, "/tmp/sketerm entry {d}", .{c.getpid()});
    const f2 = c.fopen(sp_name.ptr, "wb") orelse return error.SkipZigTest;
    _ = c.fclose(f2);
    defer _ = c.unlink(sp_name.ptr);
    var uri_buf: [160]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "file:///tmp/sketerm%20entry%20{d}", .{c.getpid()});
    try std.testing.expectEqualStrings("local:/tmp", startLocation(&buf, uri));

    // A directory through the whole pipeline keeps its own path.
    try std.testing.expectEqualStrings("local:/tmp", startLocation(&buf, "file:///tmp"));
}
