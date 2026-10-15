//! Subprocess file-job runner (`sketerm-mux --job`).
//!
//! Heavy fs verbs (copy, delete_tree, hash) run here — one process
//! per OPERATION, spawned by the daemon: kill = cancel, SIGSTOP/SIGCONT = pause/resume, a crash
//! costs one job and never a session. Spec arrives as one JSON line
//! on stdin; progress leaves as JSON lines on stdout; the exit code
//! is redundant with the final done/error line (the daemon trusts
//! the line, and maps a lineless death to "helper died").
//!
//! This file is the runtime only: the spec, progress and journal
//! handling, the durable terminal buffering and the dispatch. Each
//! operation family lives in `jobs/` and reaches the runtime through
//! the `Job` it is handed; `cross_copy` is `crosscopy.zig`.
//!
//! Byte resume needs no journal: the staged partial (`<dst>.skpart`)
//! is verified against the same-length source prefix. Move recovery
//! additionally journals copy-complete/source-deleted phase boundaries.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const fsserve = @import("fsserve.zig");
const fsjournal = @import("fsjournal.zig");
const crosscopy = @import("crosscopy.zig");
const platform = @import("../util/platform.zig");
const archive = @import("jobs/archive.zig");
const copy = @import("jobs/copy.zig");
const filetools = @import("jobs/filetools.zig");
const git = @import("jobs/git.zig");
const hash = @import("jobs/hash.zig");
const media = @import("jobs/media.zig");
const preview = @import("jobs/preview.zig");
const search = @import("jobs/search.zig");
const trash = @import("jobs/trash.zig");
const tree = @import("jobs/tree.zig");

const nowMs = @import("../util/clock.zig").nowMs;

const runtime = @This();

/// Every verb the `--job` helper runs. The wire verb IS the tag name
/// (`daemon_fsjobs.jobOpFor` is a `stringToEnum`), `serve` dispatches
/// on it and `filebrowser/jobop.zig` classifies it -- one enum, so a
/// verb added here fails to compile until every consumer says what to
/// do with it. Append-only: the names are on the wire.
pub const Op = enum {
    copy,
    delete_tree,
    hash,
    find,
    grep,
    extract,
    archive_create,
    archive_list,
    archive_extract,
    trash,
    trash_restore,
    cross_copy,
    panelize,
    live_find,
    thumbnail,
    preview,
    dir_size,
    perm_tree,
    media_meta,
    preview_transport,
    preview_stream,
    git_status,
    diff,
    split,
    combine,
    secure_delete,
    git_diff,
    disk_usage,
    /// Recursive search for entries carrying a tag (`pattern`), read
    /// from each entry's tags xattr -- so tags set by another client or
    /// carried over by a copy are found too, not just indexed ones.
    tag_find,
};

/// The staged partial a copy writes beside its destination, and the
/// scoped temp name a symlink install goes through (a `-<job>` or
/// `-<pid>` scope is appended; the unscoped form is the legacy name
/// older helpers left behind and current ones still clean up).
pub const PART_SUFFIX = ".skpart";
pub const LINK_PART_SUFFIX = ".skpart-link";

pub const CHUNK: usize = 256 * 1024;
/// Distinguishes a helper's own durable-journal failure from transport
/// interruption when no terminal event can safely be emitted.
pub const JOURNAL_EXIT_CODE: u8 = 74;
/// Emit a progress line at least every this many bytes.
// 1 MiB: at typical WAN rates the panel gets a sample every second
// or two — 4 MiB made sub-4-MB/s transfers read as stalled between
// samples and turned the rate display into a sawtooth.
const PROGRESS_BYTES: u64 = 1 << 20;
/// ...and, when the entry in flight changes, no more often than this.
/// A tree of small files never crosses the byte threshold, so without
/// a second trigger the reported file would sit on the first one
/// forever; without the throttle, a 100k-entry tree would put 100k
/// path-carrying lines through the daemon. How often a human can read
/// a changing filename is the honest bound, so it is a TIME one.
const PROGRESS_FILE_MS: i64 = 150;
/// Tail of the in-flight path carried on a progress line. The tail is
/// the identifying part; the head is the job's own root anyway.
const CURRENT_FILE_MAX: usize = 512;

pub const Spec = struct {
    op: []const u8 = "",
    src: []const u8 = "",
    dst: []const u8 = "",
    pattern: []const u8 = "",
    src_host: []const u8 = "",
    dst_host: []const u8 = "",
    @"resume": bool = false,
    no_replace: bool = false,
    /// copy: what to do about an entry INSIDE the tree whose name
    /// already exists at the destination ("" = overwrite, the
    /// historical behavior; also "skip" and "keep_both"). The
    /// top-level destination name is always the caller's — it owns
    /// the undo record that names it.
    conflict: []const u8 = "",
    /// copy of a directory onto an existing directory: "" / "merge"
    /// recurses and keeps destination-only entries (Finder merge),
    /// "replace" removes the destination tree first.
    dir_mode: []const u8 = "",
    job_id: u64 = 0,
    journal_dir: []const u8 = "",
    /// find: only entries modified within this window (0 = all).
    within_ms: u64 = 0,
    /// preview_stream: encode from this offset.
    start_ms: u64 = 0,
    /// find: raise the match cap (0 = default; clamped to 200k).
    max_matches: u64 = 0,
    client_token: []const u8 = "",
    /// Stable logical-transfer identity (see fsjournal.Record).
    transfer_token: []const u8 = "",
    /// perm_tree: mode to apply (0o7777 mask).
    mode: u32 = 0,
    /// perm_tree: -1 leaves the current owner/group untouched.
    uid: i64 = -1,
    gid: i64 = -1,
    /// Receiver-supported preview transport codecs, preference order.
    image_codecs: []const u8 = "",
    /// The preview transport helper owns and removes its source scratch.
    delete_source: bool = false,
    /// thumbnail: cache the transport codec bytes themselves (JXL/
    /// WebP) in this host's private wire cache and serve that file,
    /// instead of installing a freedesktop PNG and re-encoding per
    /// fetch. Remote-serving hosts only — a desktop host's PNG cache
    /// is shared with its other file managers.
    wire_cache: bool = false,
    /// cross_copy: delete the source after verified installation — a
    /// cross-host MOVE as one daemon-owned job. A failed deletion
    /// fails the job with the copy intact; the retry re-verifies by
    /// hash (cheap) and redoes only the delete.
    delete_src: bool = false,
    /// cross_copy: cap the initial dial attempts per side (0 = the
    /// full reconnect budget). A DIRECT remote-to-remote attempt sets
    /// a small cap so an unreachable peer fails in seconds and the
    /// caller falls back to relaying, instead of a minute of backoff.
    dial_tries: u32 = 0,
    /// copy: hash-compare every staged file against its source before
    /// the rename installs it (files_verify_copy).
    verify: bool = false,
    /// Durable cross_copy move boundary restored from the daemon's
    /// journal ("copied", "quarantined", or "source_deleted").
    phase: []const u8 = "",
    source_quarantine: []const u8 = "",
    destination_stage: []const u8 = "",
    source_fingerprint: []const u8 = "",
    source_kind: []const u8 = "",
    source_dev: u64 = 0,
    source_ino: u64 = 0,
    recovery_attempts: u32 = 0,
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    files_done: u64 = 0,
    files_total: u64 = 0,
};

// ── progress emission ───────────────────────────────────────────

fn emitRaw(line: []const u8) void {
    // fd 1 is the job protocol, but under `zig build test --listen=-`
    // it is the build runner's own IPC pipe: a stray progress line
    // corrupts that protocol and hangs the whole test run. Tests that
    // want the emission checked should call the encoder directly.
    if (builtin.is_test) return;
    var off: usize = 0;
    while (off < line.len) {
        const n = c.write(1, line.ptr + off, line.len - off);
        if (n <= 0) {
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            // Daemon gone: the job has no one to report to. Keep
            // running (durability) — copies finish even reporterless.
            return;
        }
        off += @intCast(n);
    }
}

pub fn encodeEvent(buf: []u8, value: anytype) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    std.json.Stringify.value(value, .{}, &w) catch return null;
    w.writeByte('\n') catch return null;
    return w.buffered();
}

/// Truncating owned copy of a caller's transient slice.
fn Str(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *@This(), text: []const u8) void {
            self.len = @min(text.len, self.buf.len);
            @memcpy(self.buf[0..self.len], text[0..self.len]);
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

const DurableProgress = struct {
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    files_done: u64 = 0,
    files_total: u64 = 0,
    phase: Str(24) = .{},
};

pub const CrossDurable = struct {
    quarantine: []const u8 = "",
    destination_stage: []const u8 = "",
    fingerprint: []const u8 = "",
    source_kind: []const u8 = "",
    source_dev: u64 = 0,
    source_ino: u64 = 0,
};

/// Durable-outcome state of the ONE job this helper process runs,
/// shared by emit/journal code that has no CrossCopy at hand.
/// Threadlocal so parallel test threads cannot share it; serve()
/// resets it wholesale.
const DurableState = struct {
    progress: DurableProgress = .{},
    retryable_cleanup: bool = false,
    cancel_requested: bool = false,
    cancel_complete: bool = false,
    delete_started: bool = false,
    error_kind: Str(32) = .{},
    message: Str(512) = .{},
    defer_terminal: bool = false,
    terminal_event: Str(32 * 1024) = .{},
};

pub threadlocal var durable_state: DurableState = .{};

fn captureDurableProgress(value: anytype) void {
    const T = @TypeOf(value);
    if (@hasField(T, "done")) durable_state.progress.done = @intCast(value.done);
    if (@hasField(T, "total")) durable_state.progress.total = @intCast(value.total);
    if (@hasField(T, "resumed_from")) durable_state.progress.resumed_from = @intCast(value.resumed_from);
    if (@hasField(T, "files_done")) durable_state.progress.files_done = @intCast(value.files_done);
    if (@hasField(T, "files_total")) durable_state.progress.files_total = @intCast(value.files_total);
    if (@hasField(T, "phase")) durable_state.progress.phase.set(value.phase);
}

pub fn emit(value: anytype) void {
    captureDurableProgress(value);
    // A 4 KiB text preview can expand sixfold under JSON escaping.
    var buf: [32 * 1024]u8 = undefined;
    const encoded = encodeEvent(&buf, value) orelse return;
    const T = @TypeOf(value);
    if (durable_state.defer_terminal and @hasField(T, "ev")) {
        const ev: []const u8 = value.ev;
        if (std.mem.eql(u8, ev, "done") or std.mem.eql(u8, ev, "error") or std.mem.eql(u8, ev, "canceled")) {
            durable_state.terminal_event.set(encoded);
            return;
        }
    }
    emitRaw(encoded);
}

pub fn emitError(msg: []const u8) u8 {
    durable_state.message.set(msg);
    emit(.{ .ev = "error", .message = msg });
    return 1;
}

/// Error whose CAUSE the caller may act on structurally.
/// "unreachable" = a cross_copy side never answered the dial — the
/// browser retries the same job through a different coordinator
/// instead of burning resume attempts.
pub fn emitErrorKind(kind: []const u8, msg: []const u8) u8 {
    durable_state.error_kind.set(kind);
    durable_state.message.set(msg);
    emit(.{ .ev = "error", .message = msg, .kind = kind });
    return 1;
}

pub fn emitCanceled(msg: []const u8) u8 {
    durable_state.cancel_complete = true;
    durable_state.message.set(msg);
    emit(.{ .ev = "canceled", .message = msg });
    return 1;
}

/// What an operation family gets from the runtime: its spec, an
/// allocator and the event output.
///
/// Families emit only through this, so the durable terminal buffering
/// in `emit` sees every event. There is no cancel probe: those jobs
/// are canceled by killing their process, and only `cross_copy`
/// (which has its own) polls for it.
pub const Job = struct {
    allocator: std.mem.Allocator,
    spec: Spec,

    pub fn emit(_: *const Job, value: anytype) void {
        runtime.emit(value);
    }

    pub fn emitError(_: *const Job, msg: []const u8) u8 {
        return runtime.emitError(msg);
    }

    pub fn emitErrorKind(_: *const Job, kind: []const u8, msg: []const u8) u8 {
        return runtime.emitErrorKind(kind, msg);
    }

    /// An error naming `what` and the errno the failed call left behind.
    pub fn emitErrno(_: *const Job, what: []const u8) u8 {
        var buf: [128]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("{s}: {s}", .{ what, fsserve.errnoName(@as(c_int, -1)) }) catch return runtime.emitError(what);
        return runtime.emitError(w.buffered());
    }

    pub fn emitCopyDone(_: *const Job, progress: *const Progress) void {
        runtime.emitCopyDone(progress);
    }
};

/// Byte and entry counters plus the identity of the entry in flight.
/// One instance per job; every progress line the job emits comes from
/// here, so the shape of a progress event is defined in one place.
pub const Progress = struct {
    done: u64 = 0,
    total: u64 = 0,
    since_emit: u64 = 0,
    /// Bytes a verified staged partial (or an already-identical
    /// destination file) contributed, cumulative across a tree.
    resumed: u64 = 0,
    /// Entries finished / expected. A zero total means "not a
    /// countable tree" and the client hides the counter.
    entries_done: u64 = 0,
    entries_total: u64 = 0,
    last_emit_ms: i64 = 0,
    emitted: bool = false,
    /// A sub-phase that shares the job's output stream but counts in
    /// different units (replace's pre-delete counts ENTRIES while the
    /// copy that follows counts BYTES). Reporting both would make the
    /// panel's byte counter jump and then reset.
    quiet: bool = false,
    /// The entry being processed right now, OWNED: a borrowed slice
    /// would dangle, since callers build paths in per-iteration
    /// stack buffers.
    file: [CURRENT_FILE_MAX]u8 = undefined,
    file_len: usize = 0,
    /// The path goes on the wire only when it CHANGED. Progress lines
    /// stream at high frequency, and a 4 KiB path on every one of them
    /// would cost more than the transfer it describes.
    file_dirty: bool = false,

    pub fn setFile(self: *Progress, path: []const u8) void {
        const tail = if (path.len <= CURRENT_FILE_MAX) path else path[path.len - CURRENT_FILE_MAX ..];
        if (std.mem.eql(u8, self.file[0..self.file_len], tail)) return;
        @memcpy(self.file[0..tail.len], tail);
        self.file_len = tail.len;
        self.file_dirty = true;
        if (!self.emitted or nowMs() - self.last_emit_ms >= PROGRESS_FILE_MS) self.emitNow();
    }

    pub fn entryDone(self: *Progress) bool {
        self.entries_done = std.math.add(u64, self.entries_done, 1) catch return false;
        return true;
    }

    pub fn add(self: *Progress, n: u64) bool {
        self.done = std.math.add(u64, self.done, n) catch return false;
        self.since_emit +|= n;
        if (self.since_emit >= PROGRESS_BYTES) self.emitNow();
        return true;
    }

    pub fn emitNow(self: *Progress) void {
        self.since_emit = 0;
        self.last_emit_ms = nowMs();
        self.emitted = true;
        if (self.quiet) return;
        emit(.{
            .ev = "progress",
            .done = self.done,
            .total = self.total,
            .resumed_from = self.resumed,
            .file = if (self.file_dirty) self.file[0..self.file_len] else "",
            .files_done = self.entries_done,
            .files_total = self.entries_total,
        });
        self.file_dirty = false;
    }
};

/// Interruptible sleep: SIGSTOP/SIGCONT (the daemon's pause control)
/// lands as EINTR here, and the remaining time is what the loop waits.
pub fn sleepMs(ms: u32) void {
    var ts = c.struct_timespec{
        .tv_sec = @intCast(ms / 1000),
        .tv_nsec = @intCast((ms % 1000) * 1_000_000),
    };
    while (true) {
        const r = c.nanosleep(&ts, &ts);
        if (r == 0) return;
        if (std.posix.errno(r) != .INTR) return;
    }
}

/// The one cancellation probe of a durable job: sticky once seen and
/// never true past the deletion boundary (crosscopy owns the rule).
pub fn cancelRequested(spec: Spec) bool {
    return crosscopy.durableCancelRequested(spec.journal_dir, spec.job_id);
}

// ── entry point (`--job`) ───────────────────────────────────────

/// Read the one-line JSON spec from stdin and run the job. The
/// process exists for exactly this operation.
pub fn serve(allocator: std.mem.Allocator) u8 {
    durable_state = .{};
    // A daemon restart closes the progress pipe. The operation must
    // continue rather than dying from SIGPIPE while reporting progress.
    platform.ignoreSigpipe();
    // Roomy enough for a media_meta batch: one line carries a base
    // directory plus a name list the daemon caps at 16 KiB, and every
    // separator costs six bytes once JSON-escaped.
    var spec_buf: [128 * 1024]u8 = undefined;
    var len: usize = 0;
    while (len < spec_buf.len) {
        const n = c.read(0, spec_buf[len..].ptr, spec_buf.len - len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        len += @intCast(n);
        if (std.mem.indexOfScalar(u8, spec_buf[0..len], '\n') != null) break;
    }
    const line_end = std.mem.indexOfScalar(u8, spec_buf[0..len], '\n') orelse len;
    const parsed = std.json.parseFromSlice(Spec, allocator, spec_buf[0..line_end], .{
        .ignore_unknown_fields = true,
    }) catch return emitError("bad job spec");
    defer parsed.deinit();
    const spec = parsed.value;
    // A durable job publishes its terminal event only after the same
    // outcome is in the journal. Otherwise a client can observe and
    // acknowledge "failed" immediately before cancellation recovery
    // commits the record back to "running".
    durable_state.defer_terminal = spec.job_id != 0 and spec.journal_dir.len != 0;
    durable_state.progress.done = spec.done;
    durable_state.progress.total = spec.total;
    durable_state.progress.resumed_from = spec.resumed_from;
    durable_state.progress.files_done = spec.files_done;
    durable_state.progress.files_total = spec.files_total;
    durable_state.progress.phase.set(spec.phase);

    const job = Job{ .allocator = allocator, .spec = spec };
    const rc: u8 = if (std.meta.stringToEnum(Op, spec.op)) |op| switch (op) {
        .copy => copy.runCopy(&job),
        .delete_tree => tree.runDeleteTree(&job),
        .hash => hash.runHash(&job),
        .find => search.runSearch(&job, false),
        .grep => search.runSearch(&job, true),
        .tag_find => search.runTagFind(&job),
        .extract => archive.runExtract(&job),
        .archive_create => archive.runArchiveCreate(&job),
        .archive_list => archive.runArchiveList(&job),
        .archive_extract => archive.runArchiveExtractMember(&job),
        .trash => trash.runTrash(&job),
        .trash_restore => trash.runTrashRestore(&job),
        .cross_copy => crosscopy.run(allocator, spec),
        .panelize => search.runPanelize(&job),
        .live_find => search.runLiveFind(&job),
        .dir_size => tree.runDirSize(&job),
        .disk_usage => tree.runDiskUsage(&job),
        .perm_tree => tree.runPermTree(&job),
        .thumbnail => preview.runPreview(&job, true),
        .preview => preview.runPreview(&job, false),
        .preview_transport => preview.runPreviewTransport(&job),
        .preview_stream => preview.runPreviewStream(&job),
        .media_meta => media.runMediaMeta(&job),
        .git_status => git.runGitStatus(&job),
        .git_diff => git.runGitDiff(&job),
        .diff => filetools.runDiff(&job),
        .split => filetools.runSplit(&job),
        .combine => filetools.runCombine(&job),
        .secure_delete => filetools.runSecureDelete(&job),
    } else emitError("unknown job op");
    const terminal_state = if (rc == 0)
        "done"
    else if (durable_state.cancel_complete)
        "canceled"
    else if (durable_state.retryable_cleanup)
        "running"
    else
        "failed";
    // On journal failure publish nothing. The daemon observes helper
    // exit, persists its own terminal reconciliation, and only then
    // emits an error; emitting here would recreate the exact
    // terminal-before-journal race this buffer prevents.
    const saved_state = saveHelperJournal(allocator, spec, terminal_state) catch return JOURNAL_EXIT_CODE;
    durable_state.defer_terminal = false;
    if (!std.mem.eql(u8, saved_state, terminal_state)) {
        if (std.mem.eql(u8, saved_state, "canceled")) {
            emit(.{ .ev = "canceled", .message = "transfer canceled; source left in place" });
        } else if (std.mem.eql(u8, saved_state, "running")) {
            emit(.{
                .ev = "error",
                .message = "cancel requested; resolving the durable source state",
                .kind = "retryable_cleanup",
            });
        }
    } else if (durable_state.terminal_event.len > 0) {
        emitRaw(durable_state.terminal_event.slice());
    }
    if (std.mem.eql(u8, saved_state, "done") or std.mem.eql(u8, saved_state, "canceled"))
        _ = fsjournal.clearCancel(spec.journal_dir, spec.job_id);
    return rc;
}

fn saveHelperJournal(allocator: std.mem.Allocator, spec: Spec, state: []const u8) ![]const u8 {
    if (spec.job_id == 0 or spec.journal_dir.len == 0) return state;
    var control: ?fsjournal.ControlLock = null;
    if ((spec.delete_src or spec.no_replace) and std.mem.eql(u8, spec.op, "cross_copy"))
        control = try fsjournal.lockControl(spec.journal_dir, spec.job_id);
    defer if (control) |guard| guard.release();
    var acknowledged = false;
    var old_done = spec.done;
    var old_total = spec.total;
    var old_resumed = spec.resumed_from;
    var old_files_done = spec.files_done;
    var old_files_total = spec.files_total;
    var old_phase = spec.phase;
    var old_quarantine = spec.source_quarantine;
    var old_destination_stage = spec.destination_stage;
    var old_fingerprint = spec.source_fingerprint;
    var old_source_kind = spec.source_kind;
    var old_source_dev = spec.source_dev;
    var old_source_ino = spec.source_ino;
    var parsed_old: ?std.json.Parsed(fsjournal.Record) = null;
    defer if (parsed_old) |*p| p.deinit();
    var path_buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&path_buf, "{s}/{d}.json", .{ spec.journal_dir, spec.job_id })) |path| {
        parsed_old = fsjournal.load(allocator, path) catch null;
        if (parsed_old) |*p| {
            acknowledged = p.value.acknowledged;
            old_done = p.value.done;
            old_total = p.value.total;
            old_resumed = p.value.resumed_from;
            old_files_done = p.value.files_done;
            old_files_total = p.value.files_total;
            if (fsjournal.phaseRank(p.value.phase) > fsjournal.phaseRank(old_phase)) old_phase = p.value.phase;
            if (old_quarantine.len == 0) old_quarantine = p.value.source_quarantine;
            if (old_destination_stage.len == 0) old_destination_stage = p.value.destination_stage;
            if (old_fingerprint.len == 0) old_fingerprint = p.value.source_fingerprint;
            if (old_source_kind.len == 0) old_source_kind = p.value.source_kind;
            if (old_source_dev == 0) old_source_dev = p.value.source_dev;
            if (old_source_ino == 0) old_source_ino = p.value.source_ino;
        }
    } else |_| {}
    const reported_phase = durable_state.progress.phase.slice();
    const phase = if (fsjournal.phaseRank(reported_phase) > fsjournal.phaseRank(old_phase)) reported_phase else old_phase;
    var saved_state: []const u8 = state;
    var message: []const u8 = durable_state.message.slice();
    var error_kind: []const u8 = durable_state.error_kind.slice();
    if (std.mem.eql(u8, state, "failed") and !durable_state.cancel_requested and
        fsjournal.cancelRequested(spec.journal_dir, spec.job_id))
    {
        // The failure raced cancellation. Source placement is not proven
        // here, even before copied (an atomic rename may be between
        // durable phases), so leave it to a recovery resolver.
        saved_state = "running";
        message = "cancel requested; resolving the durable source state";
        error_kind = "retryable_cleanup";
    }
    try fsjournal.save(spec.journal_dir, .{
        .id = spec.job_id,
        .op = spec.op,
        .state = saved_state,
        .src = spec.src,
        .dst = spec.dst,
        .pattern = spec.pattern,
        .src_host = spec.src_host,
        .dst_host = spec.dst_host,
        .@"resume" = spec.@"resume",
        .conflict = spec.conflict,
        .no_replace = spec.no_replace,
        .delete_src = spec.delete_src,
        .verify = spec.verify,
        .phase = phase,
        .source_quarantine = old_quarantine,
        .destination_stage = old_destination_stage,
        .source_fingerprint = old_fingerprint,
        .source_kind = old_source_kind,
        .source_dev = old_source_dev,
        .source_ino = old_source_ino,
        .recovery_attempts = spec.recovery_attempts,
        .pid = c.getpid(),
        .done = @max(old_done, durable_state.progress.done),
        .total = @max(old_total, durable_state.progress.total),
        .resumed_from = @max(old_resumed, durable_state.progress.resumed_from),
        .files_done = @max(old_files_done, durable_state.progress.files_done),
        .files_total = @max(old_files_total, durable_state.progress.files_total),
        .message = message,
        .error_kind = error_kind,
        .client_token = spec.client_token,
        .transfer_token = spec.transfer_token,
        .acknowledged = acknowledged,
    });
    return saved_state;
}

pub fn saveCrossPhase(spec: Spec, phase: []const u8, progress: *const Progress, durable: CrossDurable) bool {
    durable_state.progress.done = progress.done;
    durable_state.progress.total = progress.total;
    durable_state.progress.resumed_from = progress.resumed;
    durable_state.progress.files_done = progress.entries_done;
    durable_state.progress.files_total = progress.entries_total;
    if (spec.job_id == 0 or spec.journal_dir.len == 0) {
        durable_state.progress.phase.set(phase);
        return true;
    }
    fsjournal.save(spec.journal_dir, .{
        .id = spec.job_id,
        .op = spec.op,
        .state = "running",
        .src = spec.src,
        .dst = spec.dst,
        .pattern = spec.pattern,
        .src_host = spec.src_host,
        .dst_host = spec.dst_host,
        .@"resume" = spec.@"resume",
        .conflict = spec.conflict,
        .no_replace = spec.no_replace,
        .delete_src = spec.delete_src,
        .verify = spec.verify,
        .phase = phase,
        .source_quarantine = durable.quarantine,
        .destination_stage = durable.destination_stage,
        .source_fingerprint = durable.fingerprint,
        .source_kind = durable.source_kind,
        .source_dev = durable.source_dev,
        .source_ino = durable.source_ino,
        .recovery_attempts = spec.recovery_attempts,
        .pid = c.getpid(),
        .done = progress.done,
        .total = progress.total,
        .resumed_from = progress.resumed,
        .files_done = progress.entries_done,
        .files_total = progress.entries_total,
        .error_kind = "",
        .client_token = spec.client_token,
        .transfer_token = spec.transfer_token,
    }) catch return false;
    durable_state.progress.phase.set(phase);
    return true;
}

pub fn emitCrossPhase(phase: []const u8, progress: *const Progress) void {
    emit(.{
        .ev = "progress",
        .done = progress.done,
        .total = progress.total,
        .resumed_from = progress.resumed,
        .files_done = progress.entries_done,
        .files_total = progress.entries_total,
        .phase = phase,
    });
}

pub fn persistCrossPhase(spec: Spec, phase: []const u8, progress: *const Progress, durable: CrossDurable) bool {
    if (!saveCrossPhase(spec, phase, progress, durable)) return false;
    emitCrossPhase(phase, progress);
    return true;
}

/// Terminal event of a copy job. Its shape is shared by the file and
/// the tree path so the two can never drift.
pub fn emitCopyDone(progress: *const Progress) void {
    emit(.{
        .ev = "done",
        .done = progress.done,
        .total = progress.total,
        .resumed_from = progress.resumed,
        .files_done = progress.entries_done,
        .files_total = progress.entries_total,
    });
}

// ── tests ───────────────────────────────────────────────────────

test "preview event carries a fully escaped 4 KiB text head" {
    var text: [4096]u8 = undefined;
    @memset(&text, 1);
    var encoded: [32 * 1024]u8 = undefined;
    const line = encodeEvent(&encoded, .{ .ev = "done", .text = &text }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(line.len > text.len);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
}

test "durable terminal events stay buffered until journal commit" {
    durable_state.defer_terminal = true;
    durable_state.terminal_event.len = 0;
    defer {
        durable_state.defer_terminal = false;
        durable_state.terminal_event.len = 0;
    }

    emit(.{ .ev = "error", .message = "deferred", .kind = "transport" });
    try std.testing.expect(durable_state.terminal_event.len > 0);
    const buffered = durable_state.terminal_event.slice();
    try std.testing.expect(std.mem.indexOf(u8, buffered, "\"ev\":\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buffered, "\"message\":\"deferred\"") != null);

    durable_state.defer_terminal = false;
    durable_state.terminal_event.len = 0;
    emit(.{ .ev = "progress", .done = @as(u64, 1) });
    try std.testing.expectEqual(@as(usize, 0), durable_state.terminal_event.len);
}

test "helper journals retain progress and explicit move phase" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const dir = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/jobs", .{&tmp.sub_path});
    const spec = Spec{
        .op = "cross_copy",
        .src = "/source",
        .dst = "/destination",
        .src_host = "src",
        .dst_host = "dst",
        .@"resume" = true,
        .delete_src = true,
        .no_replace = true,
        .job_id = 73,
        .journal_dir = dir,
        .client_token = "move-73",
    };
    const progress = Progress{
        .done = 99,
        .total = 123,
        .resumed = 11,
        .entries_done = 7,
        .entries_total = 9,
        .quiet = true,
    };
    durable_state.progress = .{};
    durable_state.cancel_requested = false;
    durable_state.error_kind.set("permanent");
    durable_state.message.set("copy failed permanently");
    try t.expect(persistCrossPhase(spec, "copied", &progress, .{
        .quarantine = "/.sketerm-move-73-deadbeef",
        .fingerprint = "0123456789abcdef",
        .source_kind = "file",
        .source_dev = 4,
        .source_ino = 5,
    }));
    // A terminal error carries no counters. Its final helper write must
    // preserve the durable copy boundary and progress rather than zero it.
    durable_state.progress.done = 0;
    durable_state.progress.total = 0;
    durable_state.progress.resumed_from = 0;
    durable_state.progress.files_done = 0;
    durable_state.progress.files_total = 0;
    durable_state.progress.phase.len = 0;
    _ = try saveHelperJournal(t.allocator, spec, "failed");
    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/73.json", .{dir});
    const parsed = try fsjournal.load(arena.allocator(), path);
    defer parsed.deinit();
    try t.expectEqualStrings("failed", parsed.value.state);
    try t.expectEqualStrings("copied", parsed.value.phase);
    try t.expectEqual(@as(u64, 99), parsed.value.done);
    try t.expectEqual(@as(u64, 123), parsed.value.total);
    try t.expectEqual(@as(u64, 11), parsed.value.resumed_from);
    try t.expectEqual(@as(u64, 7), parsed.value.files_done);
    try t.expectEqual(@as(u64, 9), parsed.value.files_total);
    try t.expect(parsed.value.no_replace);
    try t.expectEqualStrings("/.sketerm-move-73-deadbeef", parsed.value.source_quarantine);
    try t.expectEqualStrings("0123456789abcdef", parsed.value.source_fingerprint);
    try t.expectEqualStrings("file", parsed.value.source_kind);
    try t.expectEqual(@as(u64, 4), parsed.value.source_dev);
    try t.expectEqual(@as(u64, 5), parsed.value.source_ino);
    try t.expectEqualStrings("copy failed permanently", parsed.value.message);
    try t.expectEqualStrings("permanent", parsed.value.error_kind);
}
