//! Named, session-scoped persistence for declarative panel documents.
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
//!     $XDG_STATE_HOME/sketerm/panels/by-session/<encoded>/<name>.json
//!     $XDG_STATE_HOME/sketerm/panels/no-session/<name>.json
//!
//! Two PARENT directories, not one namespace with a reserved name in
//! it: a caller with no session (an `sketerm mcp` outside any pane) is
//! a different shape, not a session called something special, so there
//! is nothing for a real session name to collide with no matter what
//! the daemon called it. In code that difference is `?[]const u8` —
//! `null` is "no session", and no string value means it.
//!
//! Files hold the CANONICAL form produced by
//! `doc.Document.toJson` — sorted keys, fixed field order,
//! byte-stable across round-trips, so a stored panel diffs cleanly and
//! re-saving an unchanged document rewrites identical bytes.
//!
//! Writes are staged into `.<name>.<pid>.sketerm-part` in the same
//! directory and `rename(2)`d into place, so a crash mid-save can never
//! leave a half-written document that fails to parse on the next load.
//! The staging name starts with a dot and does not end in `.json`, so a
//! leftover from a killed process is invisible to `list`.
//!
//! libc file IO only (Zig 0.16 has no `std.fs.cwd`). GTK-free: in both
//! test roots.

const std = @import("std");
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");
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
    IoFailed,
    OutOfMemory,
};

/// 1 MiB — the same ceiling `doc.parse` enforces on input, so a
/// document that parses always fits and the cap can only trip on a
/// hostile/corrupt file rather than on legitimate authoring.
pub const MAX_BYTES: usize = doc.MAX_JSON_BYTES;

/// Panels stored per session. An assistant in a save loop hits this
/// (reported as `TooMany`, naming the cap) instead of the user's disk.
pub const MAX_PANELS: usize = 64;

pub const MAX_NAME: usize = 64;
pub const MAX_SESSION: usize = 64;

/// Parent of every real session's panel directory.
pub const BY_SESSION_DIR: []const u8 = "by-session";

/// Where panels land when the caller has no session: `sketerm mcp` can
/// run outside any pane, and refusing to save at all there would make
/// the feature unusable from a bare shell. A SIBLING of
/// `BY_SESSION_DIR`, never a directory inside it, so no session name —
/// encoded or not — can address it.
pub const NO_SESSION_DIR: []const u8 = "no-session";

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
pub fn validName(name: []const u8) bool {
    return validComponent(name, MAX_NAME);
}

/// A session is INHERITED, never chosen by the caller: the daemon
/// accepts any 1..64 bytes as a session name and exports it verbatim
/// as `$SKETERM_SESSION`, so `my work` is a perfectly legal session.
/// Rejecting it on charset would make panels unusable from that pane
/// with nothing the user could do about it, so only the length rule
/// is a rejection here; everything else is encoded (`encodeSession`).
pub fn validSession(session: []const u8) bool {
    return session.len > 0 and session.len <= MAX_SESSION;
}

/// Longest encoded session directory name: every byte may expand to
/// `%XX`.
pub const MAX_SESSION_DIR: usize = MAX_SESSION * 3;

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
pub fn encodeSession(buf: []u8, session: []const u8) Error![]u8 {
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

/// The session a caller should use: an explicit one when given, else
/// `$SKETERM_SESSION`, else NONE. `null` is a real answer, not a
/// fallback name — the sessionless bucket is a different directory,
/// not a session called something. The result borrows from `explicit`
/// or from the environment; it is never allocated.
pub fn resolveSession(explicit: ?[]const u8) ?[]const u8 {
    if (norm(explicit)) |s| return s;
    return getenv("SKETERM_SESSION");
}

fn checkSession(session: ?[]const u8, diag: ?*Diag) Error!void {
    const s = norm(session) orelse return; // sessionless: its own bucket
    if (!validSession(s)) {
        if (diag) |d| d.set("invalid session \"{s}\": must be 1..{d} bytes (the daemon's own cap)", .{ s, MAX_SESSION });
        return Error.BadSession;
    }
}

fn checkKey(session: ?[]const u8, name: []const u8, diag: ?*Diag) Error!void {
    try checkSession(session, diag);
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

fn panelPath(allocator: std.mem.Allocator, session: ?[]const u8, name: []const u8, diag: ?*Diag) Error![]u8 {
    try checkKey(session, name, diag);
    const dir = try sessionDir(allocator, session);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir, name }) catch Error.OutOfMemory;
}

fn stagePath(allocator: std.mem.Allocator, session: ?[]const u8, name: []const u8) Error![]u8 {
    const dir = try sessionDir(allocator, session);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/.{s}.{d}.sketerm-part", .{ dir, name, c.getpid() }) catch Error.OutOfMemory;
}

// ─── write / read primitives ────────────────────────────────────

/// Stage `bytes` next to `path` and, when `commit`, rename it over
/// `path`. `commit = false` exists for the atomicity test: it is
/// exactly the state a crash between write and rename leaves behind.
fn writeAtomic(stage: []const u8, path: []const u8, bytes: []const u8, commit: bool) Error!void {
    pathz.makeParentDirs(path) catch return Error.IoFailed;
    var szbuf: [4096]u8 = undefined;
    const stage_z = pathz.pathZ(&szbuf, stage) catch return Error.IoFailed;
    {
        const f = c.fopen(stage_z, "wb") orelse return Error.IoFailed;
        var closed = false;
        errdefer if (!closed) {
            _ = c.fclose(f);
            _ = c.unlink(stage_z);
        };
        if (bytes.len > 0 and c.fwrite(bytes.ptr, 1, bytes.len, f) != bytes.len) return Error.IoFailed;
        if (c.fflush(f) != 0) return Error.IoFailed;
        // Durability before the rename: without it the rename can land
        // in the journal ahead of the data and a power cut yields a
        // present-but-empty panel, which is the failure this whole
        // path exists to prevent.
        _ = c.fsync(c.fileno(f));
        closed = true;
        if (c.fclose(f) != 0) {
            _ = c.unlink(stage_z);
            return Error.IoFailed;
        }
    }
    if (!commit) return;
    var pzbuf: [4096]u8 = undefined;
    const path_z = pathz.pathZ(&pzbuf, path) catch {
        _ = c.unlink(stage_z);
        return Error.IoFailed;
    };
    if (c.rename(stage_z, path_z) != 0) {
        _ = c.unlink(stage_z);
        return Error.IoFailed;
    }
}

fn readFile(allocator: std.mem.Allocator, path: []const u8) Error![]u8 {
    var zbuf: [4096]u8 = undefined;
    const z = pathz.pathZ(&zbuf, path) catch return Error.IoFailed;
    const f = c.fopen(z, "rb") orelse return Error.NotFound;
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

/// Persist `document` under `(session, name)`, replacing any previous
/// panel of that name. The canonical serialization is what lands on
/// disk, so `save` is idempotent byte-for-byte.
pub fn save(
    allocator: std.mem.Allocator,
    session: ?[]const u8,
    name: []const u8,
    document: *const Document,
    diag: ?*Diag,
) Error!void {
    try checkKey(session, name, diag);
    const bytes = document.toJson(allocator) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.Corrupt,
    };
    defer allocator.free(bytes);
    return saveBytes(allocator, session, name, bytes, diag);
}

/// Validate `json_text` as a panel document and persist it. This is
/// the entry point for an MCP tool holding agent-authored JSON: an
/// invalid document is rejected with `diag` explaining why and nothing
/// is written.
pub fn saveJson(
    allocator: std.mem.Allocator,
    session: ?[]const u8,
    name: []const u8,
    json_text: []const u8,
    diag: ?*Diag,
) Error!void {
    try checkKey(session, name, diag);
    var parsed = Document.parse(allocator, json_text, diag) catch |err| switch (err) {
        error.OutOfMemory => return Error.OutOfMemory,
        error.TooBig => return Error.TooBig,
        else => return Error.Invalid,
    };
    defer parsed.deinit();
    return save(allocator, session, name, &parsed, diag);
}

fn saveBytes(
    allocator: std.mem.Allocator,
    session: ?[]const u8,
    name: []const u8,
    bytes: []const u8,
    diag: ?*Diag,
) Error!void {
    if (bytes.len > MAX_BYTES) {
        if (diag) |d| d.set("panel \"{s}\" is {d} bytes, over the {d}-byte cap", .{ name, bytes.len, MAX_BYTES });
        return Error.TooBig;
    }
    const path = try panelPath(allocator, session, name, diag);
    defer allocator.free(path);

    // The cap counts DISTINCT panels: overwriting an existing name is
    // always allowed, so an assistant updating one panel never trips it.
    if (!fileExists(path)) {
        const n = try countPanels(allocator, session);
        if (n >= MAX_PANELS) {
            if (diag) |d| d.set("session {s} already holds {d} panels (cap {d}); delete one first", .{ sessionLabel(session), n, MAX_PANELS });
            return Error.TooMany;
        }
    }

    const stage = try stagePath(allocator, session, name);
    defer allocator.free(stage);
    return writeAtomic(stage, path, bytes, true);
}

/// Parse a stored panel. `Corrupt` (with `diag` set by the parser)
/// means the file exists but no longer describes a valid document —
/// never a crash and never a silently empty panel.
pub fn load(
    allocator: std.mem.Allocator,
    session: ?[]const u8,
    name: []const u8,
    diag: ?*Diag,
) Error!Document {
    const bytes = try loadJson(allocator, session, name, diag);
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
pub fn loadJson(
    allocator: std.mem.Allocator,
    session: ?[]const u8,
    name: []const u8,
    diag: ?*Diag,
) Error![]u8 {
    const path = try panelPath(allocator, session, name, diag);
    defer allocator.free(path);
    return readFile(allocator, path) catch |err| {
        if (err == Error.NotFound) {
            if (diag) |d| d.set("no panel \"{s}\" saved in session {s}", .{ name, sessionLabel(session) });
        }
        return err;
    };
}

pub fn exists(allocator: std.mem.Allocator, session: ?[]const u8, name: []const u8) bool {
    const path = panelPath(allocator, session, name, null) catch return false;
    defer allocator.free(path);
    return fileExists(path);
}

pub fn delete(allocator: std.mem.Allocator, session: ?[]const u8, name: []const u8, diag: ?*Diag) Error!void {
    const path = try panelPath(allocator, session, name, diag);
    defer allocator.free(path);
    var zbuf: [4096]u8 = undefined;
    const z = pathz.pathZ(&zbuf, path) catch return Error.IoFailed;
    if (c.unlink(z) != 0) {
        if (diag) |d| d.set("no panel \"{s}\" saved in session {s}", .{ name, sessionLabel(session) });
        return Error.NotFound;
    }
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

/// Every panel stored for `session`, sorted by name. Free with
/// `freeList`. An unknown or never-used session lists empty rather
/// than erroring — "no panels yet" is not a failure.
pub fn list(allocator: std.mem.Allocator, session: ?[]const u8) Error![]Entry {
    const dir = try sessionDir(allocator, session);
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
    const d = c.opendir(z) orelse return out; // never-used session
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

fn countPanels(allocator: std.mem.Allocator, session: ?[]const u8) Error!usize {
    const dir = try sessionDir(allocator, session);
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
    try t.expectError(Error.BadName, saveJson(t.allocator, "s1", "../../evil", DOC, &diag));
    try t.expect(std.mem.indexOf(u8, diag.msg(), "panel name") != null);
    try t.expectError(Error.BadName, load(t.allocator, "s1", "a/b", null));

    // The SESSION is inherited: it must work, and must stay inside the
    // panels root as one encoded directory.
    try saveJson(t.allocator, "../../etc", "p", DOC, null);
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
    try saveJson(t.allocator, "my work", "p", DOC, null);
    try saveJson(t.allocator, "my/work", "p",
        \\{"root":"r","title":"Slashed","components":{"r":{"type":"text","text":"s"}}}
    , null);
    var spaced = try load(t.allocator, "my work", "p", null);
    defer spaced.deinit();
    try t.expectEqualStrings("VSR compare", spaced.title);
    var slashed = try load(t.allocator, "my/work", "p", null);
    defer slashed.deinit();
    try t.expectEqualStrings("Slashed", slashed.title);
    const spaced_list = try list(t.allocator, "my work");
    defer freeList(t.allocator, spaced_list);
    try t.expectEqual(@as(usize, 1), spaced_list.len);

    // An over-long session is still refused, with the reason.
    diag = Diag{};
    try t.expectError(Error.BadSession, saveJson(t.allocator, "x" ** 65, "p", DOC, &diag));
    try t.expect(std.mem.indexOf(u8, diag.msg(), "session") != null);
    try t.expectError(Error.BadSession, delete(t.allocator, "x" ** 65, "p", null));
}

test "the sessionless bucket shares no namespace with any session" {
    var scratch: Scratch = undefined;
    try scratch.init("nosession");
    defer scratch.deinit();

    // The full sessionless lifecycle works without a session at all.
    try saveJson(t.allocator, null, "p", DOC, null);
    var loaded = try load(t.allocator, null, "p", null);
    defer loaded.deinit();
    try t.expectEqualStrings("VSR compare", loaded.title);
    try t.expect(exists(t.allocator, null, "p"));
    {
        const listed = try list(t.allocator, null);
        defer freeList(t.allocator, listed);
        try t.expectEqual(@as(usize, 1), listed.len);
        try t.expectEqualStrings("p", listed[0].name);
    }

    // A session LITERALLY named `_no-session` (the old sentinel) is an
    // ordinary session: its panels are somewhere else entirely, and
    // neither side can see or overwrite the other's.
    try saveJson(t.allocator, "_no-session", "p",
        \\{"root":"r","title":"Impostor","components":{"r":{"type":"text","text":"i"}}}
    , null);
    var impostor = try load(t.allocator, "_no-session", "p", null);
    defer impostor.deinit();
    try t.expectEqualStrings("Impostor", impostor.title);
    var sessionless = try load(t.allocator, null, "p", null);
    defer sessionless.deinit();
    try t.expectEqualStrings("VSR compare", sessionless.title);

    // Same for the directory name the bucket happens to use, and for
    // the parent every real session lives under.
    for ([_][]const u8{ NO_SESSION_DIR, BY_SESSION_DIR }) |spoof| {
        try saveJson(t.allocator, spoof, "p",
            \\{"root":"r","title":"Spoof","components":{"r":{"type":"text","text":"s"}}}
        , null);
        var spoofed = try load(t.allocator, spoof, "p", null);
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
        const listed = try list(t.allocator, null);
        defer freeList(t.allocator, listed);
        try t.expectEqual(@as(usize, 1), listed.len);
    }

    // Deleting the sessionless panel touches nothing else.
    try delete(t.allocator, null, "p", null);
    try t.expect(!exists(t.allocator, null, "p"));
    try t.expect(exists(t.allocator, "_no-session", "p"));

    // The string-typed edges spell "no session" as the empty string,
    // which is not a session name in any layer — same bucket, and an
    // explicit "" is never a session of its own.
    try saveJson(t.allocator, "", "empty", DOC, null);
    try t.expect(exists(t.allocator, null, "empty"));
}

test "save/load round-trip keeps the document byte-stable" {
    var scratch: Scratch = undefined;
    try scratch.init("roundtrip");
    defer scratch.deinit();

    try saveJson(t.allocator, "s1", "vsr-compare", DOC, null);

    var loaded = try load(t.allocator, "s1", "vsr-compare", null);
    defer loaded.deinit();
    try t.expectEqualStrings("VSR compare", loaded.title);
    try t.expectEqualStrings("main", loaded.root);
    try t.expectEqual(@as(usize, 3), loaded.components.count());
    try t.expectEqualStrings("PSNR +0.4 dB", loaded.get("note").?.props.text.text);

    // Re-saving the parsed document must produce the same bytes.
    const first = try loadJson(t.allocator, "s1", "vsr-compare", null);
    defer t.allocator.free(first);
    try save(t.allocator, "s1", "vsr-compare", &loaded, null);
    const second = try loadJson(t.allocator, "s1", "vsr-compare", null);
    defer t.allocator.free(second);
    try t.expectEqualStrings(first, second);

    try t.expect(exists(t.allocator, "s1", "vsr-compare"));
    try delete(t.allocator, "s1", "vsr-compare", null);
    try t.expect(!exists(t.allocator, "s1", "vsr-compare"));
    try t.expectError(Error.NotFound, load(t.allocator, "s1", "vsr-compare", null));
    try t.expectError(Error.NotFound, delete(t.allocator, "s1", "vsr-compare", null));
}

test "listing is session-isolated and carries metadata" {
    var scratch: Scratch = undefined;
    try scratch.init("sessions");
    defer scratch.deinit();

    try saveJson(t.allocator, "alpha", "shared-name", DOC, null);
    try saveJson(t.allocator, "alpha", "zulu", DOC, null);
    try saveJson(t.allocator, "beta", "shared-name",
        \\{"root":"r","title":"Beta's panel","components":{"r":{"type":"text","text":"b"}}}
    , null);

    const a_list = try list(t.allocator, "alpha");
    defer freeList(t.allocator, a_list);
    try t.expectEqual(@as(usize, 2), a_list.len);
    try t.expectEqualStrings("shared-name", a_list[0].name);
    try t.expectEqualStrings("zulu", a_list[1].name);
    try t.expectEqualStrings("VSR compare", a_list[0].title);
    try t.expect(a_list[0].ok);
    try t.expect(a_list[0].bytes > 0);
    try t.expect(a_list[0].mtime > 0);

    const b_list = try list(t.allocator, "beta");
    defer freeList(t.allocator, b_list);
    try t.expectEqual(@as(usize, 1), b_list.len);
    try t.expectEqualStrings("Beta's panel", b_list[0].title);

    // Same name, different content: neither session can see the other's.
    var from_beta = try load(t.allocator, "beta", "shared-name", null);
    defer from_beta.deinit();
    try t.expectEqualStrings("Beta's panel", from_beta.title);

    // A never-used session lists empty rather than erroring.
    const empty = try list(t.allocator, "gamma");
    defer freeList(t.allocator, empty);
    try t.expectEqual(@as(usize, 0), empty.len);
}

test "a crash between write and rename leaves no partial document" {
    var scratch: Scratch = undefined;
    try scratch.init("atomic");
    defer scratch.deinit();

    try saveJson(t.allocator, "s1", "keeper", DOC, null);
    const before = try loadJson(t.allocator, "s1", "keeper", null);
    defer t.allocator.free(before);

    // Exactly what a kill between fwrite and rename leaves behind.
    const path = try panelPath(t.allocator, "s1", "keeper", null);
    defer t.allocator.free(path);
    const stage = try stagePath(t.allocator, "s1", "keeper");
    defer t.allocator.free(stage);
    try writeAtomic(stage, path, "{ truncated garba", false);

    // The old document is intact and still parses...
    const after = try loadJson(t.allocator, "s1", "keeper", null);
    defer t.allocator.free(after);
    try t.expectEqualStrings(before, after);
    var still = try load(t.allocator, "s1", "keeper", null);
    still.deinit();

    // ...and the abandoned staging file is invisible to the store.
    try t.expect(fileExists(stage));
    const entries = try list(t.allocator, "s1");
    defer freeList(t.allocator, entries);
    try t.expectEqual(@as(usize, 1), entries.len);
    try t.expectEqualStrings("keeper", entries[0].name);

    // The next real save commits and clears nothing else.
    try saveJson(t.allocator, "s1", "keeper", DOC, null);
    const again = try loadJson(t.allocator, "s1", "keeper", null);
    defer t.allocator.free(again);
    try t.expectEqualStrings(before, again);
}

test "a corrupt stored file reports a diagnostic" {
    var scratch: Scratch = undefined;
    try scratch.init("corrupt");
    defer scratch.deinit();

    try saveJson(t.allocator, "s1", "broken", DOC, null);
    const path = try panelPath(t.allocator, "s1", "broken", null);
    defer t.allocator.free(path);
    const stage = try stagePath(t.allocator, "s1", "broken");
    defer t.allocator.free(stage);
    try writeAtomic(stage, path, "{\"root\":\"gone\",\"components\":{}}", true);

    var diag = Diag{};
    try t.expectError(Error.Corrupt, load(t.allocator, "s1", "broken", &diag));
    try t.expect(diag.len > 0);
    try t.expect(std.mem.indexOf(u8, diag.msg(), "gone") != null);

    // Not JSON at all is the same story, not a crash.
    try writeAtomic(stage, path, "\x00\xffnot json", true);
    diag = Diag{};
    try t.expectError(Error.Corrupt, load(t.allocator, "s1", "broken", &diag));
    try t.expect(diag.len > 0);

    // Listing still works and flags it.
    const entries = try list(t.allocator, "s1");
    defer freeList(t.allocator, entries);
    try t.expectEqual(@as(usize, 1), entries.len);
    try t.expect(!entries[0].ok);
    try t.expectEqualStrings("", entries[0].title);

    // An invalid document is refused BEFORE anything is written, and
    // is reported as Invalid (bad input), not Corrupt (bad file).
    diag = Diag{};
    try t.expectError(Error.Invalid, saveJson(t.allocator, "s1", "never", "{\"nope\":1}", &diag));
    try t.expect(diag.len > 0);
    try t.expect(!exists(t.allocator, "s1", "never"));
}

test "caps trip and say what happened" {
    var scratch: Scratch = undefined;
    try scratch.init("caps");
    defer scratch.deinit();

    var i: usize = 0;
    while (i < MAX_PANELS) : (i += 1) {
        var namebuf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&namebuf, "p{d:0>3}", .{i});
        try saveJson(t.allocator, "s1", name, DOC, null);
    }
    var diag = Diag{};
    try t.expectError(Error.TooMany, saveJson(t.allocator, "s1", "one-too-many", DOC, &diag));
    try t.expect(std.mem.indexOf(u8, diag.msg(), "cap") != null);
    try t.expect(!exists(t.allocator, "s1", "one-too-many"));

    // Overwriting an existing panel is never blocked by the count cap.
    try saveJson(t.allocator, "s1", "p000", DOC, null);
    // A different session has its own budget.
    try saveJson(t.allocator, "s2", "one-too-many", DOC, null);

    // Oversize documents are refused by the parser's own ceiling.
    const big = try t.allocator.alloc(u8, MAX_BYTES + 1);
    defer t.allocator.free(big);
    @memset(big, 'x');
    diag = Diag{};
    try t.expectError(Error.TooBig, saveJson(t.allocator, "s1", "huge", big, &diag));
    try t.expect(!exists(t.allocator, "s1", "huge"));
}

test "resolveSession prefers explicit, then env, else there is no session" {
    _ = c.unsetenv("SKETERM_SESSION");
    // Not a fallback NAME: the absence is the answer, and the type says so.
    try t.expectEqual(@as(?[]const u8, null), resolveSession(null));
    try t.expectEqual(@as(?[]const u8, null), resolveSession(""));
    try t.expectEqualStrings("explicit", resolveSession("explicit").?);
    _ = c.setenv("SKETERM_SESSION", "pane-7", 1);
    defer _ = c.unsetenv("SKETERM_SESSION");
    try t.expectEqualStrings("pane-7", resolveSession(null).?);
    try t.expectEqualStrings("explicit", resolveSession("explicit").?);
    try t.expectEqualStrings("(no session)", sessionLabel(null));
    try t.expectEqualStrings("(no session)", sessionLabel(""));
    try t.expectEqualStrings("pane-7", sessionLabel("pane-7"));
}
