//! Crash recovery for unsaved editor buffers (core half).
//!
//! WHY A SNAPSHOT JOURNAL AND NOT AN EDIT LOG
//!
//! An append-only log of transactions would be cheaper per keystroke,
//! but it only replays correctly against the exact base bytes it was
//! recorded from — which, for a file that a build tool rewrote while
//! the editor was down, no longer exist. Recovery would then be a
//! rebase, and a wrong rebase silently corrupts the user's work. A
//! whole-buffer snapshot is self-contained: what is written is exactly
//! what the user sees, so recovery is a comparison, never a merge. The
//! cost is bounded by debouncing (`shouldWrite`) and by the fact that
//! only DIRTY buffers are ever journaled.
//!
//! OWNERSHIP — the rule everything else depends on
//!
//! Each record is a pair of files in the journal directory:
//!
//!   * `<key>.lock` — created and flock'ed EXCLUSIVELY before the
//!     record file exists, held for as long as the owning process runs.
//!     A lock that can be taken therefore means "no live owner", which
//!     is exactly the crash predicate: a live editor's record is never
//!     offered for recovery, and a dead one's always is. `flock` (not
//!     `fcntl`) because fcntl locks are per PROCESS and are dropped by
//!     closing ANY descriptor to the file.
//!   * `<key>.rec` — one JSON header line, '\n', then the raw buffer
//!     bytes. Replaced through `util/atomicwrite.zig` (unique exclusive
//!     stage, fsync, rename, directory fsync), so a reader never sees a
//!     half-written record. The header
//!     is JSON for forward compatibility; the content is NOT, because
//!     JSON-escaping a 100MB buffer on every autosave is not a cost
//!     worth paying.
//!
//! A `.lock` with no `.rec` is the debris of a process that died
//! between the two steps; `list` removes it.
//!
//! KEYING — `<identity-hash>-<instance-token>`. The identity half is a
//! hash of the host-qualified spec ("/path" or "host:/path"), so
//! records for one file are greppable and `staleFor` can find them.
//! The instance half is random per handle, so two editors (two GUI
//! processes, or the same file opened twice) never clobber each other's
//! record and both survive to be offered at recovery time.
//!
//! REMOTE DOCUMENTS are journaled exactly like local ones: the snapshot
//! is the buffer, not the file, so recovery works with the remote host
//! unreachable. What recovery must NOT do is write the buffer back —
//! see `Recovered.baseline`, which carries the disk identity observed
//! at load/save time so the UI can tell "the file is untouched" from
//! "the file moved on under us" and let the user decide.
//!
//! UI WIRING CONTRACT (not wired yet — `src/ui/editorview.zig` owns it)
//!
//!   * per tab, on the first edit that makes the buffer dirty:
//!     `journal.open(alloc, spec orelse "")` → store the `Handle` on the
//!     tab. Keep the handle for the tab's lifetime; the lock it holds is
//!     what tells other processes this buffer is alive.
//!   * on a debounce timer (a second of idle, say) while dirty:
//!     `if (h.shouldWrite(doc.revision)) try h.writeDocument(&doc, hdr)`
//!     with `hdr.spec`/`hdr.remote`/`hdr.cursor` filled from the tab and
//!     `hdr.setBaseline(tab.disk)` from its `reload.DiskState`.
//!     `error.BufferTooLarge` means "recovery is off for this buffer" —
//!     surface it, do not retry.
//!   * after a successful save: `doc.markSaved(); h.clear()` (keeps the
//!     lock, drops the snapshot). On tab close or a clean quit:
//!     `h.discard()`.
//!   * at startup, before restoring the layout: `journal.list(alloc)` →
//!     offer each `Entry` (`header.spec`, `header.updated_ms`), then
//!     `journal.read(alloc, key)` for the ones the user takes, build the
//!     tab with `Document.initVerbatim(rec.content, style)` — NOT
//!     `initFromBytes`, which re-sniffs the style and would strip the
//!     CRs out of an LF buffer holding pasted CRLF lines — plus the
//!     caret at `header.cursor` and the style from `header.crlf`, mark
//!     it dirty (it IS unsaved work), and `journal.remove(alloc, key)`
//!     ONLY once it opened. Compare
//!     `rec.baseline()` against a fresh stat with `reload.compare` and
//!     show the verdict rather than saving anything automatically.
//!   * a periodic `journal.prune(alloc, ...)` (a week, say) keeps
//!     declined records from living forever.
//!
//! GTK-free and allocator-explicit: this file is part of the core test
//! root and must stay buildable in the `sketerm-mux` dependency set.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("../c.zig").c;
const pathz = @import("../util/pathz.zig");
const atomicwrite = @import("../util/atomicwrite.zig");
const doc_mod = @import("document.zig");
const Document = doc_mod.Document;
const reload = @import("reload.zig");

pub const VERSION: u32 = 1;
pub const MIN_READ_VERSION: u32 = 1;

/// Buffers larger than this are not journaled: the write would stall
/// the UI thread and the crash window it protects is small compared to
/// the cost. `Handle.write` answers `error.BufferTooLarge` so the face
/// can tell the user recovery is off for that buffer.
pub const MAX_CONTENT: usize = 64 * 1024 * 1024;

/// A header line longer than this is corruption, not a header.
pub const MAX_HEADER_BYTES: usize = 64 * 1024;

pub const Error = error{
    BufferTooLarge,
    RecordCorrupt,
    /// The file could not be OPENED or read (fd exhaustion, a transient
    /// permission error). Distinct from `RecordCorrupt` because it says
    /// nothing about the bytes: only a record we can prove is debris may
    /// be deleted, and conflating the two threw away every unreadable
    /// record on a startup that happened to run out of descriptors.
    RecordUnreadable,
    /// The header did not parse, but its `version` field says a NEWER
    /// sketerm wrote it. Never debris.
    RecordNewer,
    RecordTooOld,
    WriteFailed,
    PathTooLong,
    NoJournalDir,
};

/// The persisted header. Every field has a default so an older record
/// still parses after the struct grows.
pub const Header = struct {
    version: u32 = VERSION,
    /// Host-qualified location ("/path", "host:/path"), or "" for a
    /// buffer that was never associated with a file (Untitled).
    spec: []const u8 = "",
    /// True when `spec` names a file on another host.
    remote: bool = false,
    /// `.crlf` documents are stored LF-normalized, exactly as they live
    /// in memory; this is what a save must re-apply.
    crlf: bool = false,
    /// Document revision the snapshot was taken at, and the revision
    /// that was last saved to disk. Unequal is what "unsaved" means.
    revision: u64 = 0,
    saved_revision: u64 = 0,
    /// Primary caret offset, so recovery restores the cursor too.
    cursor: u64 = 0,
    content_len: u64 = 0,
    content_hash: u64 = 0,
    /// Wall-clock ms of the last write, for "unsaved changes from
    /// <when>" in the recovery UI and for pruning.
    updated_ms: i64 = 0,
    /// Owning process at write time. Informational only — liveness is
    /// decided by the lock, never by testing a pid.
    pid: i64 = 0,
    /// Disk identity observed at the last load/save (reload.DiskState),
    /// so recovery can report whether the file changed underneath.
    disk_known: bool = false,
    disk_present: bool = false,
    disk_mtime_ns: i64 = 0,
    disk_mtime_ms: i64 = 0,
    disk_size: u64 = 0,
    disk_ino: u64 = 0,
    disk_mode: u32 = 0,

    pub fn baseline(self: Header) reload.DiskState {
        return .{
            .known = self.disk_known,
            .present = self.disk_present,
            .mtime_ns = self.disk_mtime_ns,
            .mtime_ms = self.disk_mtime_ms,
            .size = self.disk_size,
            .ino = self.disk_ino,
            .mode = self.disk_mode,
        };
    }

    pub fn setBaseline(self: *Header, st: reload.DiskState) void {
        self.disk_known = st.known;
        self.disk_present = st.present;
        self.disk_mtime_ns = st.mtime_ns;
        self.disk_mtime_ms = st.mtime_ms;
        self.disk_size = st.size;
        self.disk_ino = st.ino;
        self.disk_mode = st.mode;
    }
};

pub fn readableVersion(v: u32) bool {
    return v >= MIN_READ_VERSION and v <= VERSION;
}

// ---- paths ------------------------------------------------------------

fn getenv(name: [*:0]const u8) ?[]const u8 {
    const raw = c.getenv(name) orelse return null;
    const s = std.mem.span(raw);
    return if (s.len == 0) null else s;
}

/// `$XDG_STATE_HOME/sketerm/editor-recovery.d`, matching where the rest
/// of sketerm keeps recoverable state (layout's last.json, the file
/// transfer ledger).
pub fn dirPath(alloc: Allocator) ![]u8 {
    if (getenv("XDG_STATE_HOME")) |xs|
        return std.fmt.allocPrint(alloc, "{s}/sketerm/editor-recovery.d", .{xs});
    if (getenv("HOME")) |home|
        return std.fmt.allocPrint(alloc, "{s}/.local/state/sketerm/editor-recovery.d", .{home});
    return alloc.dupe(u8, "/tmp/sketerm-editor-recovery.d");
}

fn ensureDir(path: []const u8) !void {
    var z: [4096]u8 = undefined;
    try pathz.makeParentDirs(path);
    const p = try pathz.pathZ(&z, path);
    if (c.mkdir(p, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) {
        // mkdir already returned; re-check with stat rather than trust
        // the errno path, which differs between libcs on EEXIST races.
        var st: c.struct_stat = undefined;
        if (c.stat(p, &st) != 0) return Error.NoJournalDir;
    }
}

const wallMs = @import("../util/clock.zig").wallMs;

fn randomToken() u64 {
    var buf: [8]u8 = undefined;
    if (c.getentropy(&buf, buf.len) != 0) {
        // Entropy is never unavailable in practice; a monotonic clock
        // mixed with the pid is still unique enough to key a record.
        var ts: std.c.timespec = undefined;
        _ = std.c.clock_gettime(.MONOTONIC, &ts);
        return @as(u64, @bitCast(@as(i64, ts.nsec))) ^ (@as(u64, @intCast(c.getpid())) << 32);
    }
    return std.mem.readInt(u64, &buf, .little);
}

/// Stable hash of a buffer identity, i.e. the first half of a record
/// key. Untitled buffers all share the empty spec's hash; the instance
/// token in the second half is what keeps their records apart.
pub fn identityHash(spec: []const u8) u64 {
    return std.hash.Wyhash.hash(0x5c7e12, spec);
}

// ---- writing ----------------------------------------------------------

/// One owned record: the lock that proves this process is alive plus
/// the paths it governs.
pub const Handle = struct {
    alloc: Allocator,
    key: []u8,
    rec_path: []u8,
    lock_path: []u8,
    lock_fd: c_int = -1,
    /// Revision of the last successful write; `shouldWrite` compares
    /// against it so an idle buffer costs nothing.
    written_revision: ?u64 = null,

    pub fn release(self: *Handle) void {
        if (self.lock_fd >= 0) _ = c.close(self.lock_fd);
        self.lock_fd = -1;
        self.alloc.free(self.key);
        self.alloc.free(self.rec_path);
        self.alloc.free(self.lock_path);
        self.* = undefined;
    }

    /// Delete the record and drop ownership — the clean-save/close path.
    pub fn discard(self: *Handle) void {
        var z: [4096]u8 = undefined;
        if (pathz.pathZ(&z, self.rec_path)) |p| {
            _ = c.unlink(p);
        } else |_| {}
        if (pathz.pathZ(&z, self.lock_path)) |p| {
            _ = c.unlink(p);
        } else |_| {}
        self.release();
    }

    /// Remove the snapshot but keep the lock, for a buffer that just
    /// became clean and may go dirty again.
    pub fn clear(self: *Handle) void {
        var z: [4096]u8 = undefined;
        if (pathz.pathZ(&z, self.rec_path)) |p| {
            _ = c.unlink(p);
        } else |_| {}
        self.written_revision = null;
    }

    /// True when a snapshot at `revision` would differ from the last one
    /// written. The caller still owns the debounce policy (a timer, an
    /// idle callback); this only answers "is there anything new".
    pub fn shouldWrite(self: *const Handle, revision: u64) bool {
        const w = self.written_revision orelse return true;
        return w != revision;
    }

    /// Snapshot a document. `header` supplies the identity fields; the
    /// content-derived ones are filled in here.
    pub fn writeDocument(self: *Handle, doc: *const Document, header: Header) !void {
        const text = try doc.textAlloc(self.alloc);
        defer self.alloc.free(text);
        var h = header;
        h.revision = doc.revision;
        h.saved_revision = doc.saved_revision;
        h.crlf = doc.line_ending == .crlf;
        try self.write(h, text);
    }

    /// Snapshot arbitrary bytes (the buffer as it lives in memory:
    /// LF-normalized when `header.crlf`).
    pub fn write(self: *Handle, header: Header, content: []const u8) !void {
        if (content.len > MAX_CONTENT) return Error.BufferTooLarge;
        var h = header;
        h.version = VERSION;
        h.content_len = content.len;
        h.content_hash = std.hash.Wyhash.hash(0xc0ffee, content);
        h.updated_ms = wallMs();
        h.pid = @intCast(c.getpid());

        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        try std.json.Stringify.value(h, .{}, &out.writer);
        const header_json = out.written();
        // The framing is "one line of JSON": a newline inside it would
        // make the content start in the wrong place.
        std.debug.assert(std.mem.indexOfScalar(u8, header_json, '\n') == null);

        const blob = try self.alloc.alloc(u8, header_json.len + 1 + content.len);
        defer self.alloc.free(blob);
        @memcpy(blob[0..header_json.len], header_json);
        blob[header_json.len] = '\n';
        @memcpy(blob[header_json.len + 1 ..], content);

        try writeFileAtomic(self.rec_path, blob);
        self.written_revision = h.revision;
    }
};

/// Claim a journal slot for one buffer. The lock is held until
/// `release`/`discard`, which is what makes every OTHER record for the
/// same file recoverable and this one not.
pub fn open(alloc: Allocator, spec: []const u8) !Handle {
    const dir = try dirPath(alloc);
    defer alloc.free(dir);
    try ensureDir(dir);

    const key = try std.fmt.allocPrint(alloc, "{x:0>16}-{x:0>16}", .{
        identityHash(spec), randomToken(),
    });
    errdefer alloc.free(key);
    const rec_path = try std.fmt.allocPrint(alloc, "{s}/{s}.rec", .{ dir, key });
    errdefer alloc.free(rec_path);
    const lock_path = try std.fmt.allocPrint(alloc, "{s}/{s}.lock", .{ dir, key });
    errdefer alloc.free(lock_path);

    var z: [4096]u8 = undefined;
    const fd = c.open(try pathz.pathZ(&z, lock_path), c.O_RDWR | c.O_CREAT | c.O_CLOEXEC, @as(c_uint, 0o600));
    if (fd < 0) return Error.WriteFailed;
    errdefer _ = c.close(fd);
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return Error.WriteFailed;

    return .{
        .alloc = alloc,
        .key = key,
        .rec_path = rec_path,
        .lock_path = lock_path,
        .lock_fd = fd,
    };
}

/// Replace a record durably.
///
/// The shared writer, not a local copy: its stage is unique per CALL (two
/// concurrent snapshot saves in one process shared `.tmp-<pid>` and
/// corrupted each other) and it opens `O_EXCL|O_NOFOLLOW`, where `fopen`
/// followed a symlink planted in the journal directory. It also syncs the
/// parent, so a crash cannot resurrect the OLD snapshot as recovered work.
fn writeFileAtomic(path: []const u8, bytes: []const u8) !void {
    atomicwrite.writeFileExact(path, bytes, 0o600) catch return Error.WriteFailed;
}

// ---- reading ----------------------------------------------------------

/// One recoverable record, as offered to the user.
///
/// `header`'s slices live in `parsed`'s arena, so the entry must be
/// deinited, not just dropped.
pub const Entry = struct {
    /// Record key; pass it back to `read`/`remove`.
    key: []u8,
    header: Header,
    /// Byte length of the record's JSON header line, i.e. where the
    /// content starts (after the '\n').
    header_len: usize,
    parsed: std.json.Parsed(Header),

    pub fn deinit(self: *Entry, alloc: Allocator) void {
        if (self.key.len > 0) alloc.free(self.key);
        self.parsed.deinit();
    }
};

pub fn freeEntries(alloc: Allocator, entries: []Entry) void {
    for (entries) |*e| e.deinit(alloc);
    alloc.free(entries);
}

/// The recovery predicate: a record is offered when it parses, its
/// version is readable, it holds unsaved work, and no live process
/// holds its lock.
pub fn isRecoverable(h: Header) bool {
    return readableVersion(h.version) and h.revision != h.saved_revision;
}

/// True when nothing holds `<key>.lock` — i.e. the owner is gone.
/// Side-effect free: the probe lock is dropped immediately.
fn ownerIsGone(lock_path: []const u8) bool {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, lock_path) catch return false;
    const fd = c.open(p, c.O_RDWR);
    if (fd < 0) return true; // no lock file at all
    defer _ = c.close(fd);
    if (c.flock(fd, c.LOCK_EX | c.LOCK_NB) != 0) return false;
    _ = c.flock(fd, c.LOCK_UN);
    return true;
}

fn parseHeaderLine(alloc: Allocator, line: []const u8) !std.json.Parsed(Header) {
    return std.json.parseFromSlice(Header, alloc, line, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return Error.RecordCorrupt;
}

/// The `version` field alone, out of a header line this binary cannot
/// otherwise parse. A future record whose schema changed incompatibly
/// (a field that stopped being a number, say) must still be identified
/// as newer, or an older binary deletes a newer one's unsaved work.
fn probeVersion(alloc: Allocator, line: []const u8) ?u32 {
    var p = std.json.parseFromSlice(
        struct { version: u32 = 0 },
        alloc,
        line,
        .{ .ignore_unknown_fields = true },
    ) catch return null;
    defer p.deinit();
    return p.value.version;
}

/// Read just the header line of one record file.
fn readHeader(alloc: Allocator, rec_path: []const u8) !Entry {
    var z: [4096]u8 = undefined;
    const fp = c.fopen(try pathz.pathZ(&z, rec_path), "rb") orelse return Error.RecordUnreadable;
    defer _ = c.fclose(fp);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(alloc);
    while (line.items.len < MAX_HEADER_BYTES) {
        const ch = c.fgetc(fp);
        if (ch < 0) break;
        if (ch == '\n') break;
        try line.append(alloc, @intCast(ch));
    }
    const parsed = parseHeaderLine(alloc, line.items) catch |err| {
        if (probeVersion(alloc, line.items)) |v| {
            if (v > VERSION) return Error.RecordNewer;
        }
        return err;
    };
    return .{
        .key = &[_]u8{},
        .header = parsed.value,
        .header_len = line.items.len,
        .parsed = parsed,
    };
}

/// Every recoverable record, newest first. Also cleans up debris: lock
/// files with no record, and records whose owner is gone but which hold
/// no unsaved work.
pub fn list(alloc: Allocator) ![]Entry {
    const dir = try dirPath(alloc);
    defer alloc.free(dir);
    var z: [4096]u8 = undefined;
    const dir_z = pathz.pathZ(&z, dir) catch return try alloc.alloc(Entry, 0);
    const dp = c.opendir(dir_z) orelse return try alloc.alloc(Entry, 0);
    defer _ = c.closedir(dp);

    var out: std.ArrayList(Entry) = .empty;
    errdefer {
        for (out.items) |*e| e.deinit(alloc);
        out.deinit(alloc);
    }

    while (c.readdir(dp)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".rec")) continue;
        const key = name[0 .. name.len - 4];

        const rec_path = try std.fmt.allocPrint(alloc, "{s}/{s}.rec", .{ dir, key });
        defer alloc.free(rec_path);
        const lock_path = try std.fmt.allocPrint(alloc, "{s}/{s}.lock", .{ dir, key });
        defer alloc.free(lock_path);
        if (!ownerIsGone(lock_path)) continue;

        var entry = readHeader(alloc, rec_path) catch |err| {
            // ONLY unparseable debris from an interrupted first write is
            // deleted. A record we merely could not open, and one a
            // NEWER sketerm wrote in a schema this binary cannot parse,
            // are both left exactly where they are: deleting either
            // throws away work.
            if (err == Error.RecordCorrupt) removePaths(rec_path, lock_path);
            continue;
        };
        errdefer entry.deinit(alloc);
        if (entry.header.version > VERSION) {
            // Written by a NEWER sketerm. Not ours to offer and, above
            // all, not ours to delete: that would throw away work this
            // binary simply cannot read.
            entry.deinit(alloc);
            continue;
        }
        if (!isRecoverable(entry.header)) {
            entry.deinit(alloc);
            removePaths(rec_path, lock_path);
            continue;
        }
        entry.key = try alloc.dupe(u8, key);
        try out.append(alloc, entry);
    }

    // A dead owner's lock file with no record is debris too, but it is
    // only safe to remove once we know no record shares the key — the
    // loop above already skipped those, so sweep now.
    sweepOrphanLocks(alloc, dir) catch {};

    const items = try out.toOwnedSlice(alloc);
    std.mem.sort(Entry, items, {}, struct {
        fn newer(_: void, a: Entry, b: Entry) bool {
            return a.header.updated_ms > b.header.updated_ms;
        }
    }.newer);
    return items;
}

fn removePaths(rec_path: []const u8, lock_path: []const u8) void {
    var z: [4096]u8 = undefined;
    if (pathz.pathZ(&z, rec_path)) |p| {
        _ = c.unlink(p);
    } else |_| {}
    if (pathz.pathZ(&z, lock_path)) |p| {
        _ = c.unlink(p);
    } else |_| {}
}

fn sweepOrphanLocks(alloc: Allocator, dir: []const u8) !void {
    var z: [4096]u8 = undefined;
    const dp = c.opendir(try pathz.pathZ(&z, dir)) orelse return;
    defer _ = c.closedir(dp);
    while (c.readdir(dp)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (!std.mem.endsWith(u8, name, ".lock")) continue;
        const key = name[0 .. name.len - 5];
        const lock_path = try std.fmt.allocPrint(alloc, "{s}/{s}.lock", .{ dir, key });
        defer alloc.free(lock_path);
        const rec_path = try std.fmt.allocPrint(alloc, "{s}/{s}.rec", .{ dir, key });
        defer alloc.free(rec_path);
        if (!ownerIsGone(lock_path)) continue;
        var st: c.struct_stat = undefined;
        var rz: [4096]u8 = undefined;
        if (c.stat(try pathz.pathZ(&rz, rec_path), &st) == 0) continue;
        var lz: [4096]u8 = undefined;
        _ = c.unlink(try pathz.pathZ(&lz, lock_path));
    }
}

pub const Recovered = struct {
    header: Header,
    /// The buffer as it lived in memory (LF-normalized when
    /// `header.crlf`). Caller-owned.
    content: []u8,
    /// Arena backing `header`'s slices.
    parsed: std.json.Parsed(Header),

    pub fn deinit(self: *Recovered, alloc: Allocator) void {
        alloc.free(self.content);
        self.parsed.deinit();
    }

    /// The disk identity observed when the buffer was last loaded or
    /// saved — feed it to `reload.compare` against a fresh stat to tell
    /// the user whether the file moved on since the crash.
    pub fn baseline(self: Recovered) reload.DiskState {
        return self.header.baseline();
    }
};

/// Load a record's header and content. `error.RecordCorrupt` when the
/// stored hash does not match — a truncated record is never handed to
/// the user as their work.
pub fn read(alloc: Allocator, key: []const u8) !Recovered {
    const dir = try dirPath(alloc);
    defer alloc.free(dir);
    const rec_path = try std.fmt.allocPrint(alloc, "{s}/{s}.rec", .{ dir, key });
    defer alloc.free(rec_path);

    var entry = try readHeader(alloc, rec_path);
    errdefer entry.deinit(alloc);
    if (!readableVersion(entry.header.version)) return Error.RecordTooOld;
    if (entry.header.content_len > MAX_CONTENT) return Error.RecordCorrupt;

    var z: [4096]u8 = undefined;
    const fp = c.fopen(try pathz.pathZ(&z, rec_path), "rb") orelse return Error.RecordCorrupt;
    defer _ = c.fclose(fp);
    if (c.fseek(fp, @intCast(entry.header_len + 1), c.SEEK_SET) != 0) return Error.RecordCorrupt;

    const n: usize = @intCast(entry.header.content_len);
    const content = try alloc.alloc(u8, n);
    errdefer alloc.free(content);
    if (n > 0 and c.fread(content.ptr, 1, n, fp) != n) return Error.RecordCorrupt;
    if (std.hash.Wyhash.hash(0xc0ffee, content) != entry.header.content_hash) return Error.RecordCorrupt;

    return .{ .header = entry.header, .content = content, .parsed = entry.parsed };
}

/// Drop a record the user declined (or already recovered).
pub fn remove(alloc: Allocator, key: []const u8) !void {
    const dir = try dirPath(alloc);
    defer alloc.free(dir);
    const rec_path = try std.fmt.allocPrint(alloc, "{s}/{s}.rec", .{ dir, key });
    defer alloc.free(rec_path);
    const lock_path = try std.fmt.allocPrint(alloc, "{s}/{s}.lock", .{ dir, key });
    defer alloc.free(lock_path);
    removePaths(rec_path, lock_path);
}

/// Delete unowned records older than `max_age_ms`. Recovery that is
/// never taken up would otherwise keep a copy of the user's text
/// forever.
pub fn prune(alloc: Allocator, max_age_ms: i64) !usize {
    const entries = try list(alloc);
    defer freeEntries(alloc, entries);
    const cutoff = wallMs() - max_age_ms;
    var removed: usize = 0;
    for (entries) |e| {
        if (e.header.updated_ms >= cutoff) continue;
        remove(alloc, e.key) catch continue;
        removed += 1;
    }
    return removed;
}

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;

/// Point the journal at a scratch directory for the duration of a test.
const ScopedDir = struct {
    saved: ?[]u8,
    path: []u8,
    alloc: Allocator,

    fn init(alloc: Allocator, name: []const u8) !ScopedDir {
        const saved: ?[]u8 = if (getenv("XDG_STATE_HOME")) |v| try alloc.dupe(u8, v) else null;
        const path = try std.fmt.allocPrint(alloc, "/tmp/sketerm-journal-test-{d}-{s}", .{ c.getpid(), name });
        var z: [4096]u8 = undefined;
        _ = c.mkdir(try pathz.pathZ(&z, path), 0o700);
        _ = c.setenv("XDG_STATE_HOME", try pathz.pathZ(&z, path), 1);
        return .{ .saved = saved, .path = path, .alloc = alloc };
    }

    fn deinit(self: *ScopedDir) void {
        var z: [4096]u8 = undefined;
        if (self.saved) |v| {
            _ = c.setenv("XDG_STATE_HOME", pathz.pathZ(&z, v) catch "", 1);
            self.alloc.free(v);
        } else {
            _ = c.unsetenv("XDG_STATE_HOME");
        }
        // Best-effort recursive cleanup of the scratch tree.
        var cmd_buf: [4200]u8 = undefined;
        const cmd = std.fmt.bufPrintZ(&cmd_buf, "rm -rf '{s}'", .{self.path}) catch {
            self.alloc.free(self.path);
            return;
        };
        _ = c.system(cmd.ptr);
        self.alloc.free(self.path);
    }
};

fn dirtyDoc(alloc: Allocator, text: []const u8) !Document {
    var doc = try Document.initFromBytes(alloc, text);
    errdefer doc.deinit();
    const tr = @import("transaction.zig");
    var tx = tr.Transaction.init(doc.revision);
    defer tx.deinit(alloc);
    try tx.addInsert(alloc, 0, "EDITED ");
    _ = try doc.applyTransaction(&tx);
    return doc;
}

test "journal: a crashed editor's buffer is recoverable, a live one's is not" {
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "crash");
    defer scope.deinit();

    var doc = try dirtyDoc(alloc, "hello\nworld\n");
    defer doc.deinit();

    var live = try open(alloc, "/tmp/live.txt");
    defer live.release();
    try live.writeDocument(&doc, .{ .spec = "/tmp/live.txt", .cursor = 3 });

    // A live owner holds its lock, so nothing is offered.
    {
        const entries = try list(alloc);
        defer freeEntries(alloc, entries);
        try testing.expectEqual(@as(usize, 0), entries.len);
    }

    // Simulate a crash: the process dies, so the lock goes away without
    // the record being discarded.
    var crashed = try open(alloc, "/tmp/crashed.txt");
    try crashed.writeDocument(&doc, .{ .spec = "/tmp/crashed.txt", .cursor = 7 });
    const key = try alloc.dupe(u8, crashed.key);
    defer alloc.free(key);
    crashed.release(); // closes the fd == what process death does

    const entries = try list(alloc);
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("/tmp/crashed.txt", entries[0].header.spec);
    try testing.expectEqualStrings(key, entries[0].key);
    try testing.expectEqual(@as(u64, 7), entries[0].header.cursor);
    try testing.expect(entries[0].header.revision != entries[0].header.saved_revision);

    var rec = try read(alloc, entries[0].key);
    defer rec.deinit(alloc);
    const expect = try doc.textAlloc(alloc);
    defer alloc.free(expect);
    try testing.expectEqualStrings(expect, rec.content);
    try testing.expect(!rec.header.crlf);

    // Recovering consumes the record.
    try remove(alloc, entries[0].key);
    const after = try list(alloc);
    defer freeEntries(alloc, after);
    try testing.expectEqual(@as(usize, 0), after.len);
}

test "journal: a clean save prunes the record" {
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "clean");
    defer scope.deinit();

    var doc = try dirtyDoc(alloc, "abc");
    defer doc.deinit();
    var h = try open(alloc, "/tmp/f.txt");
    try h.writeDocument(&doc, .{ .spec = "/tmp/f.txt" });
    try testing.expect(!h.shouldWrite(doc.revision));

    // The face saved the file: mark it and drop the snapshot.
    doc.markSaved();
    h.discard();

    const entries = try list(alloc);
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "journal: two editors of the same file keep separate records" {
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "two");
    defer scope.deinit();

    var doc_a = try dirtyDoc(alloc, "aaa");
    defer doc_a.deinit();
    var doc_b = try dirtyDoc(alloc, "bbb");
    defer doc_b.deinit();

    var a = try open(alloc, "/tmp/same.txt");
    var b = try open(alloc, "/tmp/same.txt");
    try testing.expect(!std.mem.eql(u8, a.key, b.key));
    try a.writeDocument(&doc_a, .{ .spec = "/tmp/same.txt" });
    try b.writeDocument(&doc_b, .{ .spec = "/tmp/same.txt" });
    a.release();
    b.release();

    const entries = try list(alloc);
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    var seen_a = false;
    var seen_b = false;
    for (entries) |e| {
        var rec = try read(alloc, e.key);
        defer rec.deinit(alloc);
        if (std.mem.indexOf(u8, rec.content, "aaa") != null) seen_a = true;
        if (std.mem.indexOf(u8, rec.content, "bbb") != null) seen_b = true;
    }
    try testing.expect(seen_a and seen_b);
}

test "journal: a saved buffer is never offered for recovery" {
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "saved");
    defer scope.deinit();

    var doc = try Document.initFromBytes(alloc, "unchanged");
    defer doc.deinit();
    var h = try open(alloc, "/tmp/clean.txt");
    try h.writeDocument(&doc, .{ .spec = "/tmp/clean.txt" });
    h.release();

    const entries = try list(alloc);
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "journal: a truncated record is refused, not handed back as work" {
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "trunc");
    defer scope.deinit();

    var doc = try dirtyDoc(alloc, "important text");
    defer doc.deinit();
    var h = try open(alloc, "/tmp/t.txt");
    try h.writeDocument(&doc, .{ .spec = "/tmp/t.txt" });
    const key = try alloc.dupe(u8, h.key);
    defer alloc.free(key);
    const rec_path = try alloc.dupe(u8, h.rec_path);
    defer alloc.free(rec_path);
    h.release();

    // Chop the tail off the content.
    var z: [4096]u8 = undefined;
    const p = try pathz.pathZ(&z, rec_path);
    var st: c.struct_stat = undefined;
    try testing.expectEqual(@as(c_int, 0), c.stat(p, &st));
    const fd = c.open(p, c.O_RDWR);
    try testing.expect(fd >= 0);
    _ = c.ftruncate(fd, @intCast(@as(u64, @intCast(st.st_size)) - 4));
    _ = c.close(fd);

    try testing.expectError(Error.RecordCorrupt, read(alloc, key));
}

test "journal: CRLF style and disk baseline survive the round trip" {
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "crlf");
    defer scope.deinit();

    var doc = try dirtyDoc(alloc, "a\r\nb\r\nc\r\n");
    defer doc.deinit();
    try testing.expectEqual(doc_mod.LineEnding.crlf, doc.line_ending);

    var header = Header{ .spec = "box:/etc/hosts", .remote = true };
    header.setBaseline(.{
        .known = true,
        .present = true,
        .mtime_ns = 123,
        .mtime_ms = 456,
        .size = 9,
        .ino = 4242,
        .mode = 0o644,
    });
    var h = try open(alloc, "box:/etc/hosts");
    try h.writeDocument(&doc, header);
    const key = try alloc.dupe(u8, h.key);
    defer alloc.free(key);
    h.release();

    var rec = try read(alloc, key);
    defer rec.deinit(alloc);
    try testing.expect(rec.header.crlf);
    try testing.expect(rec.header.remote);
    try testing.expectEqualStrings("box:/etc/hosts", rec.header.spec);
    const base = rec.baseline();
    try testing.expectEqual(@as(u64, 4242), base.ino);
    try testing.expectEqual(reload.Verdict.unchanged, reload.compare(base, base));

    // The snapshot is the in-memory (LF) text; a save re-applies CRLF.
    try testing.expectEqualStrings("EDITED a\nb\nc\n", rec.content);
}

test "journal: prune drops records older than the cutoff" {
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "prune");
    defer scope.deinit();

    var doc = try dirtyDoc(alloc, "old work");
    defer doc.deinit();
    var h = try open(alloc, "/tmp/old.txt");
    try h.write(.{ .spec = "/tmp/old.txt", .revision = 5, .saved_revision = 0 }, "old work");
    h.release();

    // A record younger than the cutoff stays.
    try testing.expectEqual(@as(usize, 0), try prune(alloc, 1000 * 60 * 60 * 24));
    // Age it past a 5ms cutoff (the stamp comes from the write, so this
    // is a real age, not a doctored field).
    _ = c.usleep(10_000);
    try testing.expectEqual(@as(usize, 1), try prune(alloc, 5));
    const entries = try list(alloc);
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "journal: a symlink at the old fixed stage name cannot be written through" {
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "symlink");
    defer scope.deinit();

    const dir = try dirPath(alloc);
    defer alloc.free(dir);
    try ensureDir(dir);

    const victim = try std.fmt.allocPrint(alloc, "{s}/victim", .{dir});
    defer alloc.free(victim);
    var victim_buf: [4096]u8 = undefined;
    const victim_z = try pathz.pathZ(&victim_buf, victim);
    const vfd = c.open(victim_z, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    try testing.expect(vfd >= 0);
    try testing.expect(c.write(vfd, "keep-me", 7) == 7);
    _ = c.close(vfd);

    // The old writer staged at `<rec>.tmp-<pid>` through fopen("wb"), which
    // follows a symlink straight out of the journal directory.
    const rec_path = try std.fmt.allocPrint(alloc, "{s}/0000000000000001-1.rec", .{dir});
    defer alloc.free(rec_path);
    const bait = try std.fmt.allocPrint(alloc, "{s}.tmp-{d}", .{ rec_path, c.getpid() });
    defer alloc.free(bait);
    var bait_buf: [4096]u8 = undefined;
    try testing.expect(c.symlink(victim_z, try pathz.pathZ(&bait_buf, bait)) == 0);

    try writeFileAtomic(rec_path, "{\"version\":1,\"spec\":\"/tmp/x\"}\nbody");

    const vfd2 = c.open(victim_z, c.O_RDONLY | c.O_CLOEXEC);
    try testing.expect(vfd2 >= 0);
    defer _ = c.close(vfd2);
    var got: [32]u8 = undefined;
    const n = c.read(vfd2, &got, got.len);
    try testing.expect(n == 7);
    try testing.expectEqualStrings("keep-me", got[0..7]);
}

test "journal: a record from a NEWER sketerm is left alone" {
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "future");
    defer scope.deinit();

    const dir = try dirPath(alloc);
    defer alloc.free(dir);
    try ensureDir(dir);
    const rec_path = try std.fmt.allocPrint(alloc, "{s}/ffffffffffffffff-1.rec", .{dir});
    defer alloc.free(rec_path);
    try writeFileAtomic(
        rec_path,
        "{\"version\":999,\"spec\":\"/tmp/x\",\"revision\":2,\"saved_revision\":1}\nbody",
    );

    const entries = try list(alloc);
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);

    // Still on disk: an older binary must never destroy a newer one's
    // unsaved work.
    var z: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    try testing.expectEqual(@as(c_int, 0), c.stat(try pathz.pathZ(&z, rec_path), &st));
}

test "journal: a NEWER record whose header does not even parse is left alone" {
    // The guard used to run AFTER the delete-on-parse-failure, so any
    // future schema change that is not merely additive made an older
    // binary destroy a newer one's unsaved work.
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "future2");
    defer scope.deinit();

    const dir = try dirPath(alloc);
    defer alloc.free(dir);
    try ensureDir(dir);
    const rec_path = try std.fmt.allocPrint(alloc, "{s}/eeeeeeeeeeeeeeee-1.rec", .{dir});
    defer alloc.free(rec_path);
    // `cursor` became an object in this imaginary future version.
    try writeFileAtomic(
        rec_path,
        "{\"version\":999,\"spec\":\"/tmp/x\",\"cursor\":{\"line\":1,\"col\":2}}\nbody",
    );

    const entries = try list(alloc);
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);

    var z: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    try testing.expectEqual(@as(c_int, 0), c.stat(try pathz.pathZ(&z, rec_path), &st));
}

test "journal: genuine debris is still swept" {
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "debris");
    defer scope.deinit();

    const dir = try dirPath(alloc);
    defer alloc.free(dir);
    try ensureDir(dir);
    const rec_path = try std.fmt.allocPrint(alloc, "{s}/dddddddddddddddd-1.rec", .{dir});
    defer alloc.free(rec_path);
    try writeFileAtomic(rec_path, "not json at all\nbody");

    const entries = try list(alloc);
    defer freeEntries(alloc, entries);
    try testing.expectEqual(@as(usize, 0), entries.len);

    var z: [4096]u8 = undefined;
    var st: c.struct_stat = undefined;
    try testing.expect(c.stat(try pathz.pathZ(&z, rec_path), &st) != 0);
}

test "journal: buffers over the size cap are refused" {
    const alloc = testing.allocator;
    var scope = try ScopedDir.init(alloc, "big");
    defer scope.deinit();
    var h = try open(alloc, "/tmp/big.txt");
    defer h.discard();
    const fake = try alloc.alloc(u8, 16);
    defer alloc.free(fake);
    // Exercise the cap without allocating 64MB: write() checks length.
    var oversized: []const u8 = undefined;
    oversized.ptr = fake.ptr;
    oversized.len = MAX_CONTENT + 1;
    try testing.expectError(Error.BufferTooLarge, h.write(.{}, oversized));
}
