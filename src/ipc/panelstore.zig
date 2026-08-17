//! Origin-qualified persistence for declarative panel documents.
//!
//! A third store in the style of `mcpassets.zig`, but with the opposite
//! sharing rule: templates and macros are deliberately shared across
//! instances, panels are deliberately NOT. Several assistants run at
//! once against the same user; each is attached to its own pane and so
//! to its own `$SKETERM_SESSION`, and one assistant's saved panels must
//! neither collide with nor be listable by another's. The session is
//! therefore a directory level, not a name prefix.
//!
//! On disk (falling back to `$HOME/.local/state`):
//!
//!     $XDG_STATE_HOME/sketerm/panels/by-origin/<socket-sha256>/<origin-id>/<name>.json
//!     $XDG_STATE_HOME/sketerm/panels/by-session/<encoded>/<name>.json
//!     $XDG_STATE_HOME/sketerm/panels/no-session/<name>.json
//!
//! `by-origin` is the exact scope: a caller that reached its session
//! through a known daemon keys on that daemon's canonical socket plus
//! the session's lifetime-unique `origin_id`, so a session rename keeps
//! its documents and a later same-name session cannot inherit them.
//! `by-session` is for callers with a session but no exact daemon (a
//! direct GUI control socket).
//!
//! Separate PARENT directories, not one namespace with a reserved name
//! in it: a caller with no session (an `sketerm mcp` outside any pane)
//! is a different shape, not a session called something special, so
//! there is nothing for a real session name to collide with no matter
//! what the daemon called it. In code that difference is `?[]const u8` —
//! `null` is "no session", and no string value means it.
//!
//! Files hold the CANONICAL form produced by
//! `doc.Document.toJson` — sorted keys, fixed field order,
//! byte-stable across round-trips, so a stored panel diffs cleanly and
//! re-saving an unchanged document rewrites identical bytes.
//!
//! Writes use the shared durable atomic writer: unique exclusive sibling
//! stage, checked write and close, data sync, rename, then parent sync.
//! A save therefore leaves either the prior document or the complete new one.
//!
//! libc file IO only (Zig 0.16 has no `std.fs.cwd`). GTK-free: in both
//! test roots.

const std = @import("std");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const pathz = @import("../util/pathz.zig");
const wire = @import("../mux/wire.zig");
const doc = @import("../ui/panel/doc.zig");

pub const Document = doc.Document;
pub const Diag = doc.Diag;

pub const Error = error{
    /// Panel name is empty, too long, or contains anything but
    /// `[A-Za-z0-9._-]` (and never a leading dot).
    BadName,
    /// Session identifier is longer than the daemon's own 64-byte cap.
    /// Nothing else about a session is rejected — see `encodeSession`.
    /// A `null` (or empty) session is not an error: it is the
    /// sessionless bucket.
    BadSession,
    /// A daemon origin must be an exact canonical absolute socket path.
    BadOrigin,
    NotFound,
    /// Document larger than `MAX_BYTES`.
    TooBig,
    /// Session already holds `MAX_PANELS` distinct panels.
    TooMany,
    /// The document handed to `saveJson` is not a valid panel document;
    /// nothing was written. `diag` carries the parser's message.
    Invalid,
    /// The STORED bytes no longer parse — the file exists but the panel
    /// cannot be opened.
    Corrupt,
    PermissionDenied,
    ReadOnlyFileSystem,
    IoFailed,
    OutOfMemory,
};

/// 1 MiB — the same ceiling `doc.parse` enforces on input, so a
/// document that parses always fits and the cap can only trip on a
/// hostile/corrupt file rather than on legitimate authoring.
const MAX_BYTES: usize = doc.MAX_JSON_BYTES;

/// Panels stored per session. An assistant in a save loop hits this
/// (reported as `TooMany`, naming the cap) instead of the user's disk.
const MAX_PANELS: usize = 64;

pub const MAX_NAME: usize = 64;
pub const MAX_SESSION: usize = 64;
const MAX_ORIGIN: usize = 4096;

/// Parent of every real session's panel directory.
pub const BY_SESSION_DIR: []const u8 = "by-session";

/// Exact lifetime identities. The daemon component is SHA-256 of its exact
/// canonical socket path, with an `origin` file beside it naming the path
/// the hash came from so the directory is identifiable by hand.
pub const BY_ORIGIN_DIR: []const u8 = "by-origin";

/// Where panels land when the caller has no session: `sketerm mcp` can
/// run outside any pane, and refusing to save at all there would make
/// the feature unusable from a bare shell. A SIBLING of
/// `BY_SESSION_DIR`, never a directory inside it, so no session name —
/// encoded or not — can address it.
pub const NO_SESSION_DIR: []const u8 = "no-session";

/// A session addressed through the exact daemon that owns it.
const OriginScope = struct {
    /// Canonical absolute path of that daemon's listening socket.
    daemon_origin: []const u8,
    /// The session's lifetime-unique immutable id. Rename does not move it,
    /// and a later same-name session gets a different one.
    origin_id: []const u8,
    /// Session name, for diagnostics only. Never part of a path.
    label: []const u8 = "",
};

pub const Scope = union(enum) {
    sessionless,
    /// A session with no exact daemon (a direct GUI control socket).
    session: []const u8,
    origin: OriginScope,
};

pub fn sessionScope(session: ?[]const u8) Scope {
    const s = norm(session) orelse return .sessionless;
    return .{ .session = s };
}

/// The one place "no session" is decided. `null` is the shape callers
/// should use; the empty string is accepted as the same thing because
/// the string-typed edges (the control socket's `session` field, and
/// `panelhost.sessionForPane`, which must stay a plain string for the
/// GUI's saved-panel picker) have no other way to spell it, and an
/// empty string is not a session name in any layer — the daemon caps
/// a session at 1..64 bytes, so nothing can be lost to this.
fn norm(session: ?[]const u8) ?[]const u8 {
    const s = session orelse return null;
    return if (s.len == 0) null else s;
}

/// How a session reads in a diagnostic. Sessionless is a state, not a
/// name, so it must never render as one.
pub fn sessionLabel(session: ?[]const u8) []const u8 {
    return norm(session) orelse "(no session)";
}

fn scopeLabel(scope: Scope) []const u8 {
    return switch (scope) {
        .sessionless => "(no session)",
        .session => |session| session,
        .origin => |origin| if (origin.label.len > 0) origin.label else origin.origin_id,
    };
}

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const v = c.getenv(name) orelse return null;
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(v)));
    return if (s.len == 0) null else s;
}

// ─── validation ─────────────────────────────────────────────────

fn validComponent(s: []const u8, max: usize) bool {
    if (s.len == 0 or s.len > max) return false;
    if (s[0] == '.') return false;
    for (s) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
            else => return false,
        }
    }
    return true;
}

/// Panel names are file names: no separators, no dotfiles, no bytes
/// that need quoting. Rejected, never sanitized — an assistant that
/// asked for `../../x` gets told so.
fn validName(name: []const u8) bool {
    return validComponent(name, MAX_NAME);
}

/// A session is INHERITED, never chosen by the caller: the daemon
/// accepts any 1..64 bytes as a session name and exports it verbatim
/// as `$SKETERM_SESSION`, so `my work` is a perfectly legal session.
/// Rejecting it on charset would make panels unusable from that pane
/// with nothing the user could do about it, so only the length rule
/// is a rejection here; everything else is encoded (`encodeSession`).
fn validSession(session: []const u8) bool {
    return session.len > 0 and session.len <= MAX_SESSION;
}

/// Longest encoded session directory name: every byte may expand to
/// `%XX`.
const MAX_SESSION_DIR: usize = MAX_SESSION * 3;

fn hexDigit(n: u4) u8 {
    return "0123456789ABCDEF"[n];
}

/// The directory name holding `session`'s panels, under
/// `BY_SESSION_DIR`: `[A-Za-z0-9.\-_]` pass through, every other byte
/// becomes `%XX` — and so does a LEADING `.`. That last rule is what
/// makes the encoding safe rather than merely tidy: with every `/`
/// encoded the result is one path component, and encoding a LEADING
/// `.` means that component can never be `.` or `..`, so traversal is
/// structurally impossible. The mapping is injective (`%` is itself
/// encoded), so two sessions can never collide in one directory. There
/// are no reserved names to steer around: sessionless panels live
/// under a different parent entirely. Writes into `buf`, which must
/// hold `MAX_SESSION_DIR`.
fn encodeSession(buf: []u8, session: []const u8) Error![]u8 {
    if (!validSession(session)) return Error.BadSession;
    var n: usize = 0;
    for (session, 0..) |ch, i| {
        const plain = switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => true,
            '.' => i > 0,
            else => false,
        };
        if (plain) {
            if (n + 1 > buf.len) return Error.IoFailed;
            buf[n] = ch;
            n += 1;
        } else {
            if (n + 3 > buf.len) return Error.IoFailed;
            buf[n] = '%';
            buf[n + 1] = hexDigit(@intCast(ch >> 4));
            buf[n + 2] = hexDigit(@intCast(ch & 0x0f));
            n += 3;
        }
    }
    return buf[0..n];
}

const SessionArg = union(enum) {
    absent,
    explicit: []const u8,
};

/// Resolve the session argument without collapsing absent and explicit empty.
pub fn resolveSession(arg: SessionArg) ?[]const u8 {
    return switch (arg) {
        .absent => getenv("SKETERM_SESSION"),
        .explicit => |session| norm(session),
    };
}

fn checkSession(session: ?[]const u8, diag: ?*Diag) Error!void {
    const s = norm(session) orelse return; // sessionless: its own bucket
    if (!validSession(s)) {
        if (diag) |d| d.set("invalid session \"{s}\": must be 1..{d} bytes (the daemon's own cap)", .{ s, MAX_SESSION });
        return Error.BadSession;
    }
}

fn checkScope(scope: Scope, diag: ?*Diag) Error!void {
    switch (scope) {
        .sessionless => {},
        .session => |session| try checkSession(session, diag),
        .origin => |origin| {
            try checkDaemonOrigin(origin.daemon_origin, diag);
            if (!wire.validSessionOriginId(origin.origin_id)) {
                if (diag) |d| d.set("invalid panel session origin id: expected {d} lowercase hex digits", .{wire.SESSION_ORIGIN_ID_LEN});
                return Error.BadOrigin;
            }
        },
    }
}

fn checkDaemonOrigin(origin: []const u8, diag: ?*Diag) Error!void {
    if (origin.len == 0 or origin.len > MAX_ORIGIN or origin[0] != '/') {
        if (diag) |d| d.set("invalid panel daemon origin: expected an exact canonical absolute socket path", .{});
        return Error.BadOrigin;
    }
}

fn checkScopedKey(scope: Scope, name: []const u8, diag: ?*Diag) Error!void {
    try checkScope(scope, diag);
    if (!validName(name)) {
        if (diag) |d| d.set("invalid panel name \"{s}\": 1..{d} chars of [A-Za-z0-9._-], no leading \".\"", .{ name, MAX_NAME });
        return Error.BadName;
    }
}

// ─── paths ──────────────────────────────────────────────────────

/// `<state>/sketerm/panels`. Caller frees.
fn panelsRoot(allocator: std.mem.Allocator) Error![]u8 {
    if (getenv("XDG_STATE_HOME")) |xs| {
        return std.fmt.allocPrint(allocator, "{s}/sketerm/panels", .{xs}) catch Error.OutOfMemory;
    }
    if (getenv("HOME")) |home| {
        return std.fmt.allocPrint(allocator, "{s}/.local/state/sketerm/panels", .{home}) catch Error.OutOfMemory;
    }
    return Error.IoFailed;
}

/// Directory holding `session`'s panels: `<root>/by-session/<encoded>`
/// for a real session, `<root>/no-session` for a sessionless caller.
/// The two can never be the same path — `by-session` is a directory
/// level, so no session name reaches the sessionless bucket and the
/// bucket is not a name anything can spell. Caller frees.
pub fn sessionDir(allocator: std.mem.Allocator, session: ?[]const u8) Error![]u8 {
    try checkSession(session, null);
    const root = try panelsRoot(allocator);
    defer allocator.free(root);
    const s = norm(session) orelse
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, NO_SESSION_DIR }) catch Error.OutOfMemory;
    var enc_buf: [MAX_SESSION_DIR]u8 = undefined;
    const enc = try encodeSession(&enc_buf, s);
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ root, BY_SESSION_DIR, enc }) catch Error.OutOfMemory;
}

fn originHash(origin: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(origin, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Directory for a complete persistence scope. Exact paths use the immutable
/// lifetime ID, so session rename cannot change them.
pub fn scopeDir(allocator: std.mem.Allocator, scope: Scope) Error![]u8 {
    try checkScope(scope, null);
    return switch (scope) {
        .sessionless => sessionDir(allocator, null),
        .session => |session| sessionDir(allocator, session),
        .origin => |origin| blk: {
            const root = try panelsRoot(allocator);
            defer allocator.free(root);
            const hash = originHash(origin.daemon_origin);
            break :blk std.fmt.allocPrint(allocator, "{s}/{s}/{s}/{s}", .{
                root, BY_ORIGIN_DIR, &hash, origin.origin_id,
            }) catch Error.OutOfMemory;
        },
    };
}

/// Name the socket path a hash directory came from, so `panels/by-origin`
/// is readable by a human. Best effort and never read back: it is a label,
/// not a validation record, and a failure to write it must not fail a save.
fn noteOriginPath(allocator: std.mem.Allocator, origin: OriginScope) void {
    const root = panelsRoot(allocator) catch return;
    defer allocator.free(root);
    const hash = originHash(origin.daemon_origin);
    const marker = std.fmt.allocPrint(allocator, "{s}/{s}/{s}/origin", .{
        root, BY_ORIGIN_DIR, &hash,
    }) catch return;
    defer allocator.free(marker);
    if (fileExists(marker)) return;
    pathz.makeParentDirs(marker) catch return;
    atomicwrite.writeFileExact(marker, origin.daemon_origin, 0o644) catch {};
}

fn panelPathScoped(allocator: std.mem.Allocator, scope: Scope, name: []const u8, diag: ?*Diag) Error![]u8 {
    try checkScopedKey(scope, name, diag);
    const dir = try scopeDir(allocator, scope);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir, name }) catch Error.OutOfMemory;
}

// ─── write / read primitives ────────────────────────────────────

fn errnoError(err: std.posix.E) Error {
    return switch (err) {
        .NOENT => Error.NotFound,
        .ACCES, .PERM => Error.PermissionDenied,
        .ROFS => Error.ReadOnlyFileSystem,
        else => Error.IoFailed,
    };
}

/// Preserve the store's public error distinctions across the shared writer.
fn atomicError(err: atomicwrite.Error) Error {
    return switch (err) {
        error.NotFound => Error.NotFound,
        error.PermissionDenied => Error.PermissionDenied,
        error.ReadOnlyFileSystem => Error.ReadOnlyFileSystem,
        else => Error.IoFailed,
    };
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    var zbuf: [4096]u8 = undefined;
    const z = pathz.pathZ(&zbuf, path) catch return Error.IoFailed;
    const f = c.fopen(z, "rb") orelse return errnoError(std.posix.errno(@as(c_int, -1)));
    defer _ = c.fclose(f);
    if (c.fseek(f, 0, c.SEEK_END) != 0) return Error.IoFailed;
    const len: usize = @intCast(@max(0, c.ftell(f)));
    if (c.fseek(f, 0, c.SEEK_SET) != 0) return Error.IoFailed;
    if (len > MAX_BYTES) return Error.TooBig;
    const buf = allocator.alloc(u8, len) catch return Error.OutOfMemory;
    errdefer allocator.free(buf);
    if (len > 0 and c.fread(buf.ptr, 1, len, f) != len) return Error.IoFailed;
    return buf;
}

// ─── public API ─────────────────────────────────────────────────

/// Persist `document` under `(scope, name)`, replacing any previous
/// panel of that name. The canonical serialization is what lands on
/// disk, so a save is idempotent byte-for-byte.
pub fn saveScoped(
    allocator: std.mem.Allocator,
    scope: Scope,
    name: []const u8,
    document: *const Document,
    diag: ?*Diag,
) Error!usize {
    try checkScopedKey(scope, name, diag);
    // Only a WRITE may create anything: a read of a never-used scope must
    // leave the state directory exactly as it found it.
    if (scope == .origin) noteOriginPath(allocator, scope.origin);
    const bytes = document.toJson(allocator) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.Corrupt,
    };
    defer allocator.free(bytes);
    return saveBytesScoped(allocator, scope, name, bytes, diag);
}

/// Validate `json_text` as a panel document and persist it. This is
/// the entry point for an MCP tool holding agent-authored JSON: an
/// invalid document is rejected with `diag` explaining why and nothing
/// is written.
pub fn saveJsonScoped(
    allocator: std.mem.Allocator,
    scope: Scope,
    name: []const u8,
    json_text: []const u8,
    diag: ?*Diag,
) Error!usize {
    try checkScopedKey(scope, name, diag);
    var parsed = Document.parse(allocator, json_text, diag) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.TooBig => return Error.TooBig,
        else => return Error.Invalid,
    };
    defer parsed.deinit();
    return saveScoped(allocator, scope, name, &parsed, diag);
}

fn saveBytesScoped(
    allocator: std.mem.Allocator,
    scope: Scope,
    name: []const u8,
    bytes: []const u8,
    diag: ?*Diag,
) Error!usize {
    if (bytes.len > MAX_BYTES) {
        if (diag) |d| d.set("panel \"{s}\" is {d} bytes, over the {d}-byte cap", .{ name, bytes.len, MAX_BYTES });
        return Error.TooBig;
    }
    const path = try panelPathScoped(allocator, scope, name, diag);
    defer allocator.free(path);

    // The cap counts DISTINCT panels: overwriting an existing name is
    // always allowed, so an assistant updating one panel never trips it.
    if (!fileExists(path)) {
        const n = try countPanelsScoped(allocator, scope);
        if (n >= MAX_PANELS) {
            if (diag) |d| d.set("scope {s} already holds {d} panels (cap {d}); delete one first", .{ scopeLabel(scope), n, MAX_PANELS });
            return Error.TooMany;
        }
    }

    pathz.makeParentDirs(path) catch return Error.IoFailed;
    atomicwrite.writeFileExact(path, bytes, 0o600) catch |err| return atomicError(err);
    return bytes.len;
}

/// Parse a stored panel. `Corrupt` (with `diag` set by the parser)
/// means the file exists but no longer describes a valid document —
/// never a crash and never a silently empty panel.
pub fn loadScoped(
    allocator: std.mem.Allocator,
    scope: Scope,
    name: []const u8,
    diag: ?*Diag,
) Error!Document {
    const bytes = try loadJsonScoped(allocator, scope, name, diag);
    defer allocator.free(bytes);
    return Document.parse(allocator, bytes, diag) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => {
            if (diag) |d| {
                if (d.len == 0) d.set("stored panel \"{s}\" is corrupt", .{name});
            }
            return Error.Corrupt;
        },
    };
}

/// Raw stored bytes (canonical JSON). Caller frees. No parse — use
/// this only to hand the document straight back to a client.
pub fn loadJsonScoped(
    allocator: std.mem.Allocator,
    scope: Scope,
    name: []const u8,
    diag: ?*Diag,
) Error![]u8 {
    const path = try panelPathScoped(allocator, scope, name, diag);
    defer allocator.free(path);
    return readFile(allocator, path) catch |err| {
        if (err == Error.NotFound) {
            if (diag) |d| d.set("no panel \"{s}\" saved in scope {s}", .{ name, scopeLabel(scope) });
        }
        return err;
    };
}

pub fn existsScoped(allocator: std.mem.Allocator, scope: Scope, name: []const u8) bool {
    const path = panelPathScoped(allocator, scope, name, null) catch return false;
    defer allocator.free(path);
    return fileExists(path);
}

pub fn deleteScoped(allocator: std.mem.Allocator, scope: Scope, name: []const u8, diag: ?*Diag) Error!void {
    const path = try panelPathScoped(allocator, scope, name, diag);
    defer allocator.free(path);
    atomicwrite.deleteFile(path) catch |atomic_err| {
        const err = atomicError(atomic_err);
        if (diag) |d| switch (err) {
            Error.NotFound => d.set("no panel \"{s}\" saved in scope {s}", .{ name, scopeLabel(scope) }),
            Error.PermissionDenied => d.set("permission denied deleting panel \"{s}\" from scope {s}", .{ name, scopeLabel(scope) }),
            Error.ReadOnlyFileSystem => d.set("cannot delete panel \"{s}\" from scope {s}: the filesystem is read-only", .{ name, scopeLabel(scope) }),
            else => d.set("I/O failure deleting panel \"{s}\" from scope {s}", .{ name, scopeLabel(scope) }),
        };
        return err;
    };
}

/// One stored panel, as an MCP tool wants to report it.
pub const Entry = struct {
    /// Owned by the Entry.
    name: []u8,
    /// Document title, "" when absent. Owned by the Entry.
    title: []u8,
    bytes: u64,
    /// Seconds since the epoch.
    mtime: i64,
    /// False when the file no longer parses — listed rather than
    /// hidden, so a broken panel is visible before someone tries to
    /// open it.
    ok: bool,
};

/// Every panel stored in `scope`, sorted by name. Free with
/// `freeList`. An unknown or never-used scope lists empty rather
/// than erroring — "no panels yet" is not a failure.
pub fn listScoped(allocator: std.mem.Allocator, scope: Scope) Error![]Entry {
    const dir = try scopeDir(allocator, scope);
    defer allocator.free(dir);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |e| freeEntry(allocator, e);
        entries.deinit(allocator);
    }

    var names = try dirNames(allocator, dir);
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    std.mem.sort([]u8, names.items, {}, lessName);

    for (names.items) |stem| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir, stem }) catch return Error.OutOfMemory;
        defer allocator.free(path);

        var e = Entry{
            .name = allocator.dupe(u8, stem) catch return Error.OutOfMemory,
            .title = allocator.dupe(u8, "") catch return Error.OutOfMemory,
            .bytes = 0,
            .mtime = 0,
            .ok = false,
        };
        errdefer freeEntry(allocator, e);

        var zbuf: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        if (c.stat(pathz.pathZ(&zbuf, path) catch return Error.IoFailed, &st) == 0) {
            e.bytes = @intCast(@max(0, st.st_size));
            e.mtime = mtimeSecs(st);
        }
        if (readFile(allocator, path)) |bytes| {
            defer allocator.free(bytes);
            if (Document.parse(allocator, bytes, null)) |parsed| {
                var d = parsed;
                defer d.deinit();
                allocator.free(e.title);
                e.title = allocator.dupe(u8, d.title) catch return Error.OutOfMemory;
                e.ok = true;
            } else |_| {}
        } else |_| {}

        entries.append(allocator, e) catch return Error.OutOfMemory;
    }
    return entries.toOwnedSlice(allocator) catch Error.OutOfMemory;
}

pub fn freeList(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| freeEntry(allocator, e);
    allocator.free(entries);
}

fn freeEntry(allocator: std.mem.Allocator, e: Entry) void {
    allocator.free(e.name);
    allocator.free(e.title);
}

fn lessName(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn mtimeSecs(st: c.struct_stat) i64 {
    const ts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
    return @intCast(ts.tv_sec);
}

fn fileExists(path: []const u8) bool {
    var zbuf: [4096]u8 = undefined;
    const z = pathz.pathZ(&zbuf, path) catch return false;
    var st: c.struct_stat = undefined;
    return c.stat(z, &st) == 0;
}

/// Stems of `<dir>/*.json`, skipping staging files and anything whose
/// stem is not a legal panel name.
fn dirNames(allocator: std.mem.Allocator, dir: []const u8) Error!std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |n| allocator.free(n);
        out.deinit(allocator);
    }
    var zbuf: [4096]u8 = undefined;
    const z = pathz.pathZ(&zbuf, dir) catch return Error.IoFailed;
    const d = c.opendir(z) orelse {
        const err = errnoError(std.posix.errno(@as(c_int, -1)));
        if (err == Error.NotFound) return out; // never-used session
        return err;
    };
    defer _ = c.closedir(d);
    while (c.readdir(d)) |ent| {
        const fname = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (!std.mem.endsWith(u8, fname, ".json")) continue;
        const stem = fname[0 .. fname.len - ".json".len];
        if (!validName(stem)) continue;
        const copy = allocator.dupe(u8, stem) catch return Error.OutOfMemory;
        out.append(allocator, copy) catch {
            allocator.free(copy);
            return Error.OutOfMemory;
        };
    }
    return out;
}

fn countPanelsScoped(allocator: std.mem.Allocator, scope: Scope) Error!usize {
    const dir = try scopeDir(allocator, scope);
    defer allocator.free(dir);
    var names = try dirNames(allocator, dir);
    defer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    return names.items.len;
}

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

const DOC =
    \\{"root":"main","title":"VSR compare","components":{
    \\ "main":{"type":"column","children":["h","note"]},
    \\ "h":{"type":"heading","text":"Epoch 41 vs 40","level":2},
    \\ "note":{"type":"text","text":"PSNR +0.4 dB","class":["dim"]}}}
;

/// Point the state dir at a fresh scratch directory for the duration of
/// one test. Every path in this module derives from XDG_STATE_HOME.
/// `init` takes a pointer on purpose: `path` points into `buf`, so a
/// Scratch returned by value would hand back a slice into the dead
/// init frame (which silently skipped every cleanup once).
const Scratch = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,

    fn path(self: *const Scratch) []const u8 {
        return self.buf[0..self.len];
    }

    fn init(self: *Scratch, tag: []const u8) !void {
        self.* = .{};
        const p = try std.fmt.bufPrintZ(&self.buf, "/tmp/sketerm-panels-{s}-{d}", .{ tag, c.getpid() });
        self.len = p.len;
        _ = c.mkdir(@ptrCast(&self.buf), 0o755);
        _ = c.setenv("XDG_STATE_HOME", @ptrCast(&self.buf), 1);
    }

    fn deinit(self: *Scratch) void {
        rmTree(self.path());
        _ = c.unsetenv("XDG_STATE_HOME");
        self.* = undefined;
    }
};

/// Best-effort recursive delete, for the test scratch dirs only. Names
/// are collected BEFORE anything is unlinked: deleting during readdir
/// skips entries, which quietly left half the scratch tree behind.
fn rmTree(path: []const u8) void {
    var zbuf: [4096]u8 = undefined;
    const z = pathz.pathZ(&zbuf, path) catch return;
    if (c.opendir(z)) |d| {
        const a = std.heap.page_allocator;
        var kids: std.ArrayList([]u8) = .empty;
        defer {
            for (kids.items) |k| a.free(k);
            kids.deinit(a);
        }
        while (c.readdir(d)) |ent| {
            const fname = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
            if (std.mem.eql(u8, fname, ".") or std.mem.eql(u8, fname, "..")) continue;
            const child = std.fmt.allocPrint(a, "{s}/{s}", .{ path, fname }) catch continue;
            kids.append(a, child) catch a.free(child);
        }
        _ = c.closedir(d);
        for (kids.items) |child| rmTree(child);
    }
    var st: c.struct_stat = undefined;
    if (c.stat(z, &st) != 0) return;
    if (st.st_mode & c.S_IFDIR != 0) {
        _ = c.rmdir(z);
    } else {
        _ = c.unlink(z);
    }
}

test "panel names are validated; sessions are only length-checked" {
    try t.expect(validName("vsr-compare"));
    try t.expect(validName("a.b_C-9"));
    try t.expect(!validName(""));
    try t.expect(!validName(".hidden"));
    try t.expect(!validName("../evil"));
    try t.expect(!validName("a/b"));
    try t.expect(!validName("a b"));
    try t.expect(!validName("x" ** 65));

    // A session is inherited from the daemon, which only length-checks
    // it — so every one of these is legal and must be storable.
    try t.expect(validSession("main-3"));
    try t.expect(validSession("my work"));
    try t.expect(validSession("a/../b"));
    try t.expect(validSession(".."));
    try t.expect(!validSession(""));
    try t.expect(!validSession("x" ** 65));
}

test "sessions are percent-encoded into one traversal-proof directory" {
    var buf: [MAX_SESSION_DIR]u8 = undefined;
    try t.expectEqualStrings("main-3", try encodeSession(&buf, "main-3"));
    // No name is reserved any more: `_no-session` encodes to itself and
    // is simply one more ordinary session directory.
    try t.expectEqualStrings("_no-session", try encodeSession(&buf, "_no-session"));
    try t.expectEqualStrings("my%20work", try encodeSession(&buf, "my work"));
    try t.expectEqualStrings("a%2Fb", try encodeSession(&buf, "a/b"));
    // A LEADING `.` encodes, which is what keeps the only two dangerous
    // component names ("." and "..") unreachable; an interior one is
    // harmless once every `/` is gone.
    try t.expectEqualStrings("%2E", try encodeSession(&buf, "."));
    try t.expectEqualStrings("%2E.", try encodeSession(&buf, ".."));
    try t.expectEqualStrings("a%2F..%2Fb", try encodeSession(&buf, "a/../b"));
    for ([_][]const u8{ ".", "..", "/", "a/../b", "../..", "%2E", "....", "/etc/passwd" }) |hostile| {
        const enc = try encodeSession(&buf, hostile);
        try t.expect(!std.mem.eql(u8, enc, "."));
        try t.expect(!std.mem.eql(u8, enc, ".."));
        try t.expect(std.mem.indexOfScalar(u8, enc, '/') == null);
    }
    // A leading `.` is encoded; an interior one is not, and `_` never
    // needs to be (it guarded a reserved name that no longer exists).
    try t.expectEqualStrings("_x._y", try encodeSession(&buf, "_x._y"));
    // `%` itself encodes, so the mapping cannot collide.
    try t.expectEqualStrings("a%2Fb", try encodeSession(&buf, "a/b"));
    try t.expectEqualStrings("a%252Fb", try encodeSession(&buf, "a%2Fb"));
    try t.expectError(Error.BadSession, encodeSession(&buf, ""));
}

test "a hostile panel name is rejected; a hostile session is encoded" {
    var scratch: Scratch = undefined;
    try scratch.init("traverse");
    defer scratch.deinit();
    var diag = Diag{};

    // The panel NAME is supplied by the caller: rejected, never sanitized.
    try t.expectError(Error.BadName, saveJsonScoped(t.allocator, .{ .session = "s1" }, "../../evil", DOC, &diag));
    try t.expect(std.mem.indexOf(u8, diag.msg(), "panel name") != null);
    try t.expectError(Error.BadName, loadScoped(t.allocator, .{ .session = "s1" }, "a/b", null));

    // The SESSION is inherited: it must work, and must stay inside the
    // panels root as one encoded directory.
    _ = try saveJsonScoped(t.allocator, .{ .session = "../../etc" }, "p", DOC, null);
    const dir = try sessionDir(t.allocator, "../../etc");
    defer t.allocator.free(dir);
    const root = try panelsRoot(t.allocator);
    defer t.allocator.free(root);
    const by_session = try std.fmt.allocPrint(t.allocator, "{s}/{s}/", .{ root, BY_SESSION_DIR });
    defer t.allocator.free(by_session);
    try t.expect(std.mem.startsWith(u8, dir, by_session));
    // ...as ONE component under `by-session`, so nothing escapes it.
    try t.expect(std.mem.indexOf(u8, dir[by_session.len..], "/") == null);
    try t.expect(fileExists(dir));

    // A session with a space and one with a slash both round-trip, and
    // stay isolated from each other.
    _ = try saveJsonScoped(t.allocator, .{ .session = "my work" }, "p", DOC, null);
    _ = try saveJsonScoped(t.allocator, .{ .session = "my/work" }, "p",
        \\{"root":"r","title":"Slashed","components":{"r":{"type":"text","text":"s"}}}
    , null);
    var spaced = try loadScoped(t.allocator, .{ .session = "my work" }, "p", null);
    defer spaced.deinit();
    try t.expectEqualStrings("VSR compare", spaced.title);
    var slashed = try loadScoped(t.allocator, .{ .session = "my/work" }, "p", null);
    defer slashed.deinit();
    try t.expectEqualStrings("Slashed", slashed.title);
    const spaced_list = try listScoped(t.allocator, .{ .session = "my work" });
    defer freeList(t.allocator, spaced_list);
    try t.expectEqual(@as(usize, 1), spaced_list.len);

    // An over-long session is still refused, with the reason.
    diag = Diag{};
    try t.expectError(Error.BadSession, saveJsonScoped(t.allocator, .{ .session = "x" ** 65 }, "p", DOC, &diag));
    try t.expect(std.mem.indexOf(u8, diag.msg(), "session") != null);
    try t.expectError(Error.BadSession, deleteScoped(t.allocator, .{ .session = "x" ** 65 }, "p", null));
}

test "the sessionless bucket shares no namespace with any session" {
    var scratch: Scratch = undefined;
    try scratch.init("nosession");
    defer scratch.deinit();

    // The full sessionless lifecycle works without a session at all.
    _ = try saveJsonScoped(t.allocator, .sessionless, "p", DOC, null);
    var loaded = try loadScoped(t.allocator, .sessionless, "p", null);
    defer loaded.deinit();
    try t.expectEqualStrings("VSR compare", loaded.title);
    try t.expect(existsScoped(t.allocator, .sessionless, "p"));
    {
        const listed = try listScoped(t.allocator, .sessionless);
        defer freeList(t.allocator, listed);
        try t.expectEqual(@as(usize, 1), listed.len);
        try t.expectEqualStrings("p", listed[0].name);
    }

    // A session LITERALLY named `_no-session` (the old sentinel) is an
    // ordinary session: its panels are somewhere else entirely, and
    // neither side can see or overwrite the other's.
    _ = try saveJsonScoped(t.allocator, .{ .session = "_no-session" }, "p",
        \\{"root":"r","title":"Impostor","components":{"r":{"type":"text","text":"i"}}}
    , null);
    var impostor = try loadScoped(t.allocator, .{ .session = "_no-session" }, "p", null);
    defer impostor.deinit();
    try t.expectEqualStrings("Impostor", impostor.title);
    var sessionless = try loadScoped(t.allocator, .sessionless, "p", null);
    defer sessionless.deinit();
    try t.expectEqualStrings("VSR compare", sessionless.title);

    // Same for the directory name the bucket happens to use, and for
    // the parent every real session lives under.
    for ([_][]const u8{ NO_SESSION_DIR, BY_SESSION_DIR }) |spoof| {
        _ = try saveJsonScoped(t.allocator, .{ .session = spoof }, "p",
            \\{"root":"r","title":"Spoof","components":{"r":{"type":"text","text":"s"}}}
        , null);
        var spoofed = try loadScoped(t.allocator, .{ .session = spoof }, "p", null);
        defer spoofed.deinit();
        try t.expectEqualStrings("Spoof", spoofed.title);
        const dir = try sessionDir(t.allocator, spoof);
        defer t.allocator.free(dir);
        const none_dir = try sessionDir(t.allocator, null);
        defer t.allocator.free(none_dir);
        try t.expect(!std.mem.eql(u8, dir, none_dir));
    }
    {
        // ...and the sessionless bucket still holds exactly its own one.
        const listed = try listScoped(t.allocator, .sessionless);
        defer freeList(t.allocator, listed);
        try t.expectEqual(@as(usize, 1), listed.len);
    }

    // Deleting the sessionless panel touches nothing else.
    try deleteScoped(t.allocator, .sessionless, "p", null);
    try t.expect(!existsScoped(t.allocator, .sessionless, "p"));
    try t.expect(existsScoped(t.allocator, .{ .session = "_no-session" }, "p"));

    // The string-typed edges spell "no session" as the empty string,
    // which is not a session name in any layer — same bucket, and an
    // explicit "" is never a session of its own.
    _ = try saveJsonScoped(t.allocator, .{ .session = "" }, "empty", DOC, null);
    try t.expect(existsScoped(t.allocator, .sessionless, "empty"));
}

test "save/load round-trip keeps the document byte-stable" {
    var scratch: Scratch = undefined;
    try scratch.init("roundtrip");
    defer scratch.deinit();

    const canonical_len = try saveJsonScoped(t.allocator, .{ .session = "s1" }, "vsr-compare", DOC, null);

    var loaded = try loadScoped(t.allocator, .{ .session = "s1" }, "vsr-compare", null);
    defer loaded.deinit();
    try t.expectEqualStrings("VSR compare", loaded.title);
    try t.expectEqualStrings("main", loaded.root);
    try t.expectEqual(@as(usize, 3), loaded.components.count());
    try t.expectEqualStrings("PSNR +0.4 dB", loaded.get("note").?.props.text.text);

    // Re-saving the parsed document must produce the same bytes.
    const first = try loadJsonScoped(t.allocator, .{ .session = "s1" }, "vsr-compare", null);
    defer t.allocator.free(first);
    try t.expectEqual(first.len, canonical_len);
    _ = try saveScoped(t.allocator, .{ .session = "s1" }, "vsr-compare", &loaded, null);
    const second = try loadJsonScoped(t.allocator, .{ .session = "s1" }, "vsr-compare", null);
    defer t.allocator.free(second);
    try t.expectEqualStrings(first, second);

    try t.expect(existsScoped(t.allocator, .{ .session = "s1" }, "vsr-compare"));
    try deleteScoped(t.allocator, .{ .session = "s1" }, "vsr-compare", null);
    try t.expect(!existsScoped(t.allocator, .{ .session = "s1" }, "vsr-compare"));
    try t.expectError(Error.NotFound, loadScoped(t.allocator, .{ .session = "s1" }, "vsr-compare", null));
    try t.expectError(Error.NotFound, deleteScoped(t.allocator, .{ .session = "s1" }, "vsr-compare", null));
}

test "listing is session-isolated and carries metadata" {
    var scratch: Scratch = undefined;
    try scratch.init("sessions");
    defer scratch.deinit();

    _ = try saveJsonScoped(t.allocator, .{ .session = "alpha" }, "shared-name", DOC, null);
    _ = try saveJsonScoped(t.allocator, .{ .session = "alpha" }, "zulu", DOC, null);
    _ = try saveJsonScoped(t.allocator, .{ .session = "beta" }, "shared-name",
        \\{"root":"r","title":"Beta's panel","components":{"r":{"type":"text","text":"b"}}}
    , null);

    const a_list = try listScoped(t.allocator, .{ .session = "alpha" });
    defer freeList(t.allocator, a_list);
    try t.expectEqual(@as(usize, 2), a_list.len);
    try t.expectEqualStrings("shared-name", a_list[0].name);
    try t.expectEqualStrings("zulu", a_list[1].name);
    try t.expectEqualStrings("VSR compare", a_list[0].title);
    try t.expect(a_list[0].ok);
    try t.expect(a_list[0].bytes > 0);
    try t.expect(a_list[0].mtime > 0);

    const b_list = try listScoped(t.allocator, .{ .session = "beta" });
    defer freeList(t.allocator, b_list);
    try t.expectEqual(@as(usize, 1), b_list.len);
    try t.expectEqualStrings("Beta's panel", b_list[0].title);

    // Same name, different content: neither session can see the other's.
    var from_beta = try loadScoped(t.allocator, .{ .session = "beta" }, "shared-name", null);
    defer from_beta.deinit();
    try t.expectEqualStrings("Beta's panel", from_beta.title);

    // A never-used session lists empty rather than erroring.
    const empty = try listScoped(t.allocator, .{ .session = "gamma" });
    defer freeList(t.allocator, empty);
    try t.expectEqual(@as(usize, 0), empty.len);
}

test "reading an unused store creates nothing on disk" {
    var scratch: Scratch = undefined;
    try scratch.init("read-only-reads");
    defer scratch.deinit();

    const scope = Scope{ .origin = .{
        .daemon_origin = "/tmp/untouched/mux.sock",
        .origin_id = "30000000000000000000000000000003",
        .label = "untouched",
    } };
    const dir = try scopeDir(t.allocator, scope);
    defer t.allocator.free(dir);
    const root = try panelsRoot(t.allocator);
    defer t.allocator.free(root);

    // Every read path, on a store nothing ever wrote to.
    const listed = try listScoped(t.allocator, scope);
    defer freeList(t.allocator, listed);
    try t.expectEqual(@as(usize, 0), listed.len);
    try t.expect(!existsScoped(t.allocator, scope, "p"));
    try t.expectError(Error.NotFound, loadJsonScoped(t.allocator, scope, "p", null));
    try t.expectError(Error.NotFound, deleteScoped(t.allocator, scope, "p", null));

    // Not the scope directory, not its daemon-hash parent, not even the
    // `origin` marker: only a save may create any of them.
    try t.expect(!fileExists(dir));
    const marker = try std.fmt.allocPrint(t.allocator, "{s}/{s}", .{ dir[0..std.mem.lastIndexOfScalar(u8, dir, '/').?], "origin" });
    defer t.allocator.free(marker);
    try t.expect(!fileExists(marker));
    try t.expect(!fileExists(root));

    // The very same scope, once written to, has all of it.
    _ = try saveJsonScoped(t.allocator, scope, "p", DOC, null);
    try t.expect(fileExists(dir));
    try t.expect(fileExists(marker));
}

test "origin-qualified stores isolate daemons and survive session rename" {
    var scratch: Scratch = undefined;
    try scratch.init("origins");
    defer scratch.deinit();

    const origin_a = Scope{ .origin = .{
        .daemon_origin = "/tmp/daemon-a/mux.sock",
        .origin_id = "00000000000000000000000000000001",
        .label = "spawn-name",
    } };
    const origin_b = Scope{ .origin = .{
        .daemon_origin = "/tmp/daemon-b/mux.sock",
        .origin_id = "00000000000000000000000000000001",
        .label = "spawn-name",
    } };
    _ = try saveJsonScoped(t.allocator, origin_a, "same",
        \\{"root":"r","title":"Daemon A","components":{"r":{"type":"text","text":"a"}}}
    , null);
    _ = try saveJsonScoped(t.allocator, origin_b, "same",
        \\{"root":"r","title":"Daemon B","components":{"r":{"type":"text","text":"b"}}}
    , null);

    var from_a = try loadScoped(t.allocator, origin_a, "same", null);
    defer from_a.deinit();
    var from_b = try loadScoped(t.allocator, origin_b, "same", null);
    defer from_b.deinit();
    try t.expectEqualStrings("Daemon A", from_a.title);
    try t.expectEqualStrings("Daemon B", from_b.title);
    const dir_a = try scopeDir(t.allocator, origin_a);
    defer t.allocator.free(dir_a);
    const dir_b = try scopeDir(t.allocator, origin_b);
    defer t.allocator.free(dir_b);
    try t.expect(!std.mem.eql(u8, dir_a, dir_b));

    // The mutable alias does not participate in the path: only the label
    // differs here, and it must resolve to daemon A's very directory.
    const renamed = Scope{ .origin = .{
        .daemon_origin = "/tmp/daemon-a/mux.sock",
        .origin_id = "00000000000000000000000000000001",
        .label = "renamed-alias",
    } };
    const renamed_dir = try scopeDir(t.allocator, renamed);
    defer t.allocator.free(renamed_dir);
    try t.expectEqualStrings(dir_a, renamed_dir);
    var after_rename = try loadScoped(t.allocator, renamed, "same", null);
    defer after_rename.deinit();
    try t.expectEqualStrings("Daemon A", after_rename.title);
}

test "same-name session reincarnations have isolated lifetime stores" {
    var scratch: Scratch = undefined;
    try scratch.init("reincarnation");
    defer scratch.deinit();

    const first = Scope{ .origin = .{
        .daemon_origin = "/tmp/reincarnation/mux.sock",
        .origin_id = "10000000000000000000000000000001",
        .label = "reused-name",
    } };
    const second = Scope{ .origin = .{
        .daemon_origin = "/tmp/reincarnation/mux.sock",
        .origin_id = "20000000000000000000000000000002",
        .label = "reused-name",
    } };
    _ = try saveJsonScoped(t.allocator, first, "same",
        \\{"root":"r","title":"First lifetime","components":{"r":{"type":"text","text":"one"}}}
    , null);
    _ = try saveJsonScoped(t.allocator, second, "same",
        \\{"root":"r","title":"Second lifetime","components":{"r":{"type":"text","text":"two"}}}
    , null);
    var first_doc = try loadScoped(t.allocator, first, "same", null);
    defer first_doc.deinit();
    var second_doc = try loadScoped(t.allocator, second, "same", null);
    defer second_doc.deinit();
    try t.expectEqualStrings("First lifetime", first_doc.title);
    try t.expectEqualStrings("Second lifetime", second_doc.title);
    const first_dir = try scopeDir(t.allocator, first);
    defer t.allocator.free(first_dir);
    const second_dir = try scopeDir(t.allocator, second);
    defer t.allocator.free(second_dir);
    try t.expect(!std.mem.eql(u8, first_dir, second_dir));
}

test "panel saves are private, failure-preserving, concurrent, and stage-clean" {
    var scratch: Scratch = undefined;
    try scratch.init("atomic");
    defer scratch.deinit();

    _ = try saveJsonScoped(t.allocator, .{ .session = "s1" }, "keeper", DOC, null);
    const before = try loadJsonScoped(t.allocator, .{ .session = "s1" }, "keeper", null);
    defer t.allocator.free(before);
    const path = try panelPathScoped(t.allocator, .{ .session = "s1" }, "keeper", null);
    defer t.allocator.free(path);
    var path_buf: [4096]u8 = undefined;
    const path_z = try pathz.pathZ(&path_buf, path);
    var st: c.struct_stat = undefined;
    try t.expect(c.stat(path_z, &st) == 0);
    try t.expectEqual(@as(c_uint, 0o600), @as(c_uint, @intCast(st.st_mode & 0o777)));

    const dir = try sessionDir(t.allocator, "s1");
    defer t.allocator.free(dir);
    var dir_buf: [4096]u8 = undefined;
    const dir_z = try pathz.pathZ(&dir_buf, dir);
    try t.expect(c.chmod(dir_z, 0o500) == 0);
    const failed = saveJsonScoped(t.allocator, .{ .session = "s1" }, "keeper",
        \\{"root":"r","title":"Must not land","components":{"r":{"type":"text","text":"x"}}}
    , null);
    try t.expect(c.chmod(dir_z, 0o700) == 0);
    try t.expectError(Error.PermissionDenied, failed);
    const after = try loadJsonScoped(t.allocator, .{ .session = "s1" }, "keeper", null);
    defer t.allocator.free(after);
    try t.expectEqualStrings(before, after);

    const ThreadCtx = struct {
        json: []const u8,
        failed: bool = false,

        fn run(self: *@This()) void {
            _ = saveJsonScoped(std.heap.c_allocator, .{ .session = "s1" }, "keeper", self.json, null) catch {
                self.failed = true;
                return;
            };
        }
    };
    var one = ThreadCtx{ .json =
        \\{"root":"r","title":"Writer one","components":{"r":{"type":"text","text":"one"}}}
    };
    var two = ThreadCtx{ .json =
        \\{"root":"r","title":"Writer two","components":{"r":{"type":"text","text":"two"}}}
    };
    const first = try std.Thread.spawn(.{}, ThreadCtx.run, .{&one});
    const second = try std.Thread.spawn(.{}, ThreadCtx.run, .{&two});
    first.join();
    second.join();
    try t.expect(!one.failed and !two.failed);
    var final = try loadScoped(t.allocator, .{ .session = "s1" }, "keeper", null);
    defer final.deinit();
    try t.expect(std.mem.eql(u8, final.title, "Writer one") or std.mem.eql(u8, final.title, "Writer two"));

    const dp = c.opendir(dir_z) orelse return error.TestUnexpectedResult;
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |entry| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
        try t.expect(std.mem.indexOf(u8, name, ".sketerm-tmp-") == null);
    }
}

test "delete distinguishes a missing panel from an undeletable one" {
    var scratch: Scratch = undefined;
    try scratch.init("delete-errno");
    defer scratch.deinit();

    var missing = Diag{};
    try t.expectError(Error.NotFound, deleteScoped(t.allocator, .{ .session = "mapped" }, "never-saved", &missing));
    try t.expect(std.mem.indexOf(u8, missing.msg(), "no panel") != null);

    _ = try saveJsonScoped(t.allocator, .{ .session = "mapped" }, "kept", DOC, null);
    const dir = try sessionDir(t.allocator, "mapped");
    defer t.allocator.free(dir);
    var z_buf: [4096]u8 = undefined;
    const dir_z = try pathz.pathZ(&z_buf, dir);
    try t.expect(c.chmod(dir_z, 0o500) == 0);
    defer _ = c.chmod(dir_z, 0o700);

    var denied = Diag{};
    try t.expectError(Error.PermissionDenied, deleteScoped(t.allocator, .{ .session = "mapped" }, "kept", &denied));
    try t.expect(std.mem.indexOf(u8, denied.msg(), "permission denied") != null);
    try t.expect(existsScoped(t.allocator, .{ .session = "mapped" }, "kept"));
}

test "a corrupt stored file reports a diagnostic" {
    var scratch: Scratch = undefined;
    try scratch.init("corrupt");
    defer scratch.deinit();

    _ = try saveJsonScoped(t.allocator, .{ .session = "s1" }, "broken", DOC, null);
    const path = try panelPathScoped(t.allocator, .{ .session = "s1" }, "broken", null);
    defer t.allocator.free(path);
    try atomicwrite.writeFile(path, "{\"root\":\"gone\",\"components\":{}}", 0o600);

    var diag = Diag{};
    try t.expectError(Error.Corrupt, loadScoped(t.allocator, .{ .session = "s1" }, "broken", &diag));
    try t.expect(diag.len > 0);
    try t.expect(std.mem.indexOf(u8, diag.msg(), "gone") != null);

    // Not JSON at all is the same story, not a crash.
    try atomicwrite.writeFile(path, "\x00\xffnot json", 0o600);
    diag = Diag{};
    try t.expectError(Error.Corrupt, loadScoped(t.allocator, .{ .session = "s1" }, "broken", &diag));
    try t.expect(diag.len > 0);

    // Listing still works and flags it.
    const entries = try listScoped(t.allocator, .{ .session = "s1" });
    defer freeList(t.allocator, entries);
    try t.expectEqual(@as(usize, 1), entries.len);
    try t.expect(!entries[0].ok);
    try t.expectEqualStrings("", entries[0].title);

    // An invalid document is refused BEFORE anything is written, and
    // is reported as Invalid (bad input), not Corrupt (bad file).
    diag = Diag{};
    try t.expectError(Error.Invalid, saveJsonScoped(t.allocator, .{ .session = "s1" }, "never", "{\"nope\":1}", &diag));
    try t.expect(diag.len > 0);
    try t.expect(!existsScoped(t.allocator, .{ .session = "s1" }, "never"));
}

test "caps trip and say what happened" {
    var scratch: Scratch = undefined;
    try scratch.init("caps");
    defer scratch.deinit();

    var i: usize = 0;
    while (i < MAX_PANELS) : (i += 1) {
        var namebuf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "p{d:0>3}", .{i});
        _ = try saveJsonScoped(t.allocator, .{ .session = "s1" }, name, DOC, null);
    }
    var diag = Diag{};
    try t.expectError(Error.TooMany, saveJsonScoped(t.allocator, .{ .session = "s1" }, "one-too-many", DOC, &diag));
    try t.expect(std.mem.indexOf(u8, diag.msg(), "cap") != null);
    try t.expect(!existsScoped(t.allocator, .{ .session = "s1" }, "one-too-many"));

    // Overwriting an existing panel is never blocked by the count cap.
    _ = try saveJsonScoped(t.allocator, .{ .session = "s1" }, "p000", DOC, null);
    // A different session has its own budget.
    _ = try saveJsonScoped(t.allocator, .{ .session = "s2" }, "one-too-many", DOC, null);

    // Oversize documents are refused by the parser's own ceiling.
    const big = try t.allocator.alloc(u8, MAX_BYTES + 1);
    defer t.allocator.free(big);
    @memset(big, 'x');
    diag = Diag{};
    try t.expectError(Error.TooBig, saveJsonScoped(t.allocator, .{ .session = "s1" }, "huge", big, &diag));
    try t.expect(!existsScoped(t.allocator, .{ .session = "s1" }, "huge"));
}

test "resolveSession prefers explicit, then env, else there is no session" {
    _ = c.unsetenv("SKETERM_SESSION");
    // Not a fallback NAME: the absence is the answer, and the type says so.
    try t.expectEqual(@as(?[]const u8, null), resolveSession(.absent));
    try t.expectEqual(@as(?[]const u8, null), resolveSession(.{ .explicit = "" }));
    try t.expectEqualStrings("explicit", resolveSession(.{ .explicit = "explicit" }).?);
    _ = c.setenv("SKETERM_SESSION", "pane-7", 1);
    defer _ = c.unsetenv("SKETERM_SESSION");
    try t.expectEqualStrings("pane-7", resolveSession(.absent).?);
    try t.expectEqual(@as(?[]const u8, null), resolveSession(.{ .explicit = "" }));
    try t.expectEqualStrings("explicit", resolveSession(.{ .explicit = "explicit" }).?);
    try t.expectEqualStrings("(no session)", sessionLabel(null));
    try t.expectEqualStrings("(no session)", sessionLabel(""));
    try t.expectEqualStrings("pane-7", sessionLabel("pane-7"));
}
