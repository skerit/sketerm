//! Subprocess file-job runner (`sketerm-mux --job`).
//!
//! Heavy fs verbs (copy, delete_tree, hash) run here — one process
//! per OPERATION, spawned by the daemon (docs/filebrowser-roadmap.md
//! phase 2): kill = cancel, SIGSTOP/SIGCONT = pause/resume, a crash
//! costs one job and never a session. Spec arrives as one JSON line
//! on stdin; progress leaves as JSON lines on stdout; the exit code
//! is redundant with the final done/error line (the daemon trusts
//! the line, and maps a lineless death to "helper died").
//!
//! Byte resume needs no journal: the staged partial (`<dst>.skpart`)
//! is verified against the same-length source prefix. Move recovery
//! additionally journals copy-complete/source-deleted phase boundaries.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const atomicwrite = @import("../util/atomicwrite.zig");
const png = @import("../util/png.zig");
const imagecodec = @import("../util/imagecodec.zig");
const pathz = @import("../util/pathz.zig");
const fsserve = @import("fsserve.zig");
const fsjournal = @import("fsjournal.zig");
const platform = @import("../util/platform.zig");
const muxclient = @import("client.zig");
const fsdrive = @import("../ipc/fsdrive.zig");
const thumbs = @import("../filebrowser/thumbs.zig");
const gitstatus = @import("../filebrowser/gitstatus.zig");
const gitdiff = @import("../editor/gitdiff.zig");
const mediameta = @import("mediameta.zig");
const disk_usage = @import("disk_usage.zig");
const uniqueName = @import("../filebrowser/paths.zig").uniqueName;

const Sha256 = std.crypto.hash.sha2.Sha256;

fn sigNoop(_: c_int) callconv(.c) void {}

const nowMs = @import("../util/clock.zig").nowMs;

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

/// Search caps: a runaway query costs a bounded stream, never a
/// flooded daemon pipe.
const MAX_MATCHES: usize = 2000;
const MAX_MATCHES_PER_FILE: usize = 200;
const MAX_GREP_FILE: u64 = 8 << 20;
const MAX_MATCH_LINE: usize = 300;

/// Hard ceiling a caller's `max_matches` is clamped to.
const MAX_MATCHES_CEILING: u64 = 200_000;

fn matchCapOf(spec: Spec) usize {
    if (spec.max_matches == 0) return MAX_MATCHES;
    return @intCast(@min(spec.max_matches, MAX_MATCHES_CEILING));
}

/// Wall-clock milliseconds. Relative-time predicates compare against
/// file mtimes, which are wall clock, so they cannot use nowMs().
fn wallMs() i64 {
    return @as(i64, c.time(null)) * 1000;
}

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

fn encodeEvent(buf: []u8, value: anytype) ?[]const u8 {
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

        fn set(self: *@This(), text: []const u8) void {
            self.len = @min(text.len, self.buf.len);
            @memcpy(self.buf[0..self.len], text[0..self.len]);
        }

        fn slice(self: *const @This()) []const u8 {
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

const CrossDurable = struct {
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

threadlocal var durable_state: DurableState = .{};

fn captureDurableProgress(value: anytype) void {
    const T = @TypeOf(value);
    if (@hasField(T, "done")) durable_state.progress.done = @intCast(value.done);
    if (@hasField(T, "total")) durable_state.progress.total = @intCast(value.total);
    if (@hasField(T, "resumed_from")) durable_state.progress.resumed_from = @intCast(value.resumed_from);
    if (@hasField(T, "files_done")) durable_state.progress.files_done = @intCast(value.files_done);
    if (@hasField(T, "files_total")) durable_state.progress.files_total = @intCast(value.files_total);
    if (@hasField(T, "phase")) durable_state.progress.phase.set(value.phase);
}

fn emit(value: anytype) void {
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

fn emitError(msg: []const u8) u8 {
    durable_state.message.set(msg);
    emit(.{ .ev = "error", .message = msg });
    return 1;
}

/// Error whose CAUSE the caller may act on structurally.
/// "unreachable" = a cross_copy side never answered the dial — the
/// browser retries the same job through a different coordinator
/// instead of burning resume attempts.
fn emitErrorKind(kind: []const u8, msg: []const u8) u8 {
    durable_state.error_kind.set(kind);
    durable_state.message.set(msg);
    emit(.{ .ev = "error", .message = msg, .kind = kind });
    return 1;
}

fn emitCanceled(msg: []const u8) u8 {
    durable_state.cancel_complete = true;
    durable_state.message.set(msg);
    emit(.{ .ev = "canceled", .message = msg });
    return 1;
}

fn emitErrno(what: []const u8) u8 {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("{s}: {s}", .{ what, fsserve.errnoName(@as(c_int, -1)) }) catch return emitError(what);
    return emitError(w.buffered());
}

/// Byte and entry counters plus the identity of the entry in flight.
/// One instance per job; every progress line the job emits comes from
/// here, so the shape of a progress event is defined in one place.
const Progress = struct {
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

    fn setFile(self: *Progress, path: []const u8) void {
        const tail = if (path.len <= CURRENT_FILE_MAX) path else path[path.len - CURRENT_FILE_MAX ..];
        if (std.mem.eql(u8, self.file[0..self.file_len], tail)) return;
        @memcpy(self.file[0..tail.len], tail);
        self.file_len = tail.len;
        self.file_dirty = true;
        if (!self.emitted or nowMs() - self.last_emit_ms >= PROGRESS_FILE_MS) self.emitNow();
    }

    fn entryDone(self: *Progress) bool {
        self.entries_done = std.math.add(u64, self.entries_done, 1) catch return false;
        return true;
    }

    fn add(self: *Progress, n: u64) bool {
        self.done = std.math.add(u64, self.done, n) catch return false;
        self.since_emit +|= n;
        if (self.since_emit >= PROGRESS_BYTES) self.emitNow();
        return true;
    }

    fn emitNow(self: *Progress) void {
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

// ── entry point (`--job`) ───────────────────────────────────────

/// Read the one-line JSON spec from stdin and run the job. The
/// process exists for exactly this operation.
pub fn serve(allocator: std.mem.Allocator) u8 {
    durable_state = .{};
    // A daemon restart closes the progress pipe. The operation must
    // continue rather than dying from SIGPIPE while reporting progress.
    _ = c.signal(c.SIGPIPE, &sigNoop);
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

    const rc: u8 = if (std.mem.eql(u8, spec.op, "copy"))
        runCopy(allocator, spec)
    else if (std.mem.eql(u8, spec.op, "delete_tree"))
        runDeleteTree(spec)
    else if (std.mem.eql(u8, spec.op, "hash"))
        runHash(spec)
    else if (std.mem.eql(u8, spec.op, "find"))
        runSearch(allocator, spec, false)
    else if (std.mem.eql(u8, spec.op, "grep"))
        runSearch(allocator, spec, true)
    else if (std.mem.eql(u8, spec.op, "extract"))
        runExtract(spec)
    else if (std.mem.eql(u8, spec.op, "archive_create"))
        runArchiveCreate(spec)
    else if (std.mem.eql(u8, spec.op, "archive_list"))
        runArchiveList(spec)
    else if (std.mem.eql(u8, spec.op, "archive_extract"))
        runArchiveExtractMember(spec)
    else if (std.mem.eql(u8, spec.op, "trash"))
        runTrash(spec)
    else if (std.mem.eql(u8, spec.op, "trash_restore"))
        runTrashRestore(spec)
    else if (std.mem.eql(u8, spec.op, "cross_copy"))
        runCrossCopy(allocator, spec)
    else if (std.mem.eql(u8, spec.op, "panelize"))
        runPanelize(spec)
    else if (std.mem.eql(u8, spec.op, "live_find"))
        runLiveFind(allocator, spec)
    else if (std.mem.eql(u8, spec.op, "dir_size"))
        runDirSize(spec)
    else if (std.mem.eql(u8, spec.op, "disk_usage"))
        runDiskUsage(allocator, spec)
    else if (std.mem.eql(u8, spec.op, "perm_tree"))
        runPermTree(spec)
    else if (std.mem.eql(u8, spec.op, "thumbnail"))
        runPreview(allocator, spec, true)
    else if (std.mem.eql(u8, spec.op, "preview"))
        runPreview(allocator, spec, false)
    else if (std.mem.eql(u8, spec.op, "preview_transport"))
        runPreviewTransport(allocator, spec)
    else if (std.mem.eql(u8, spec.op, "preview_stream"))
        runPreviewStream(spec)
    else if (std.mem.eql(u8, spec.op, "media_meta"))
        runMediaMeta(allocator, spec)
    else if (std.mem.eql(u8, spec.op, "git_status"))
        runGitStatus(allocator, spec)
    else if (std.mem.eql(u8, spec.op, "git_diff"))
        runGitDiff(allocator, spec)
    else if (std.mem.eql(u8, spec.op, "diff"))
        runDiff(allocator, spec)
    else if (std.mem.eql(u8, spec.op, "split"))
        runSplit(spec)
    else if (std.mem.eql(u8, spec.op, "combine"))
        runCombine(spec)
    else if (std.mem.eql(u8, spec.op, "secure_delete"))
        runSecureDelete(spec)
    else
        emitError("unknown job op");
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

fn saveCrossPhase(spec: Spec, phase: []const u8, progress: *const Progress, durable: CrossDurable) bool {
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

fn emitCrossPhase(phase: []const u8, progress: *const Progress) void {
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

fn persistCrossPhase(spec: Spec, phase: []const u8, progress: *const Progress, durable: CrossDurable) bool {
    if (!saveCrossPhase(spec, phase, progress, durable)) return false;
    emitCrossPhase(phase, progress);
    return true;
}

// ── archives ─────────────────────────────────────────────────────

fn unsafeArchiveMember(name_in: []const u8) bool {
    var name = name_in;
    while (std.mem.startsWith(u8, name, "./")) name = name[2..];
    if (name.len == 0 or name[0] == '/') return true;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return true;
    }
    return false;
}

/// List through bsdtar without a shell and reject archive members that
/// could escape the selected extraction directory.
fn archiveMembersSafe(archive: []const u8) bool {
    var az: [4096:0]u8 = undefined;
    const ap = std.fmt.bufPrintZ(&az, "{s}", .{archive}) catch return false;
    var pipefd: [2]c_int = undefined;
    if (c.pipe(&pipefd) != 0) return false;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        return false;
    }
    if (pid == 0) {
        _ = c.dup2(pipefd[1], 1);
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        const argv = [_:null]?[*:0]const u8{ "bsdtar", "-tf", ap.ptr, null };
        _ = c.execvp("bsdtar", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.close(pipefd[1]);
    var line: [4096]u8 = undefined;
    var len: usize = 0;
    var safe = true;
    var buf: [8192]u8 = undefined;
    read_loop: while (true) {
        const n = c.read(pipefd[0], &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        for (buf[0..@intCast(n)]) |ch| {
            if (ch == '\n') {
                if (unsafeArchiveMember(line[0..len])) {
                    safe = false;
                    break :read_loop;
                }
                len = 0;
            } else if (len < line.len) {
                line[len] = ch;
                len += 1;
            } else {
                safe = false;
                break :read_loop;
            }
        }
    }
    if (safe and len > 0) safe = !unsafeArchiveMember(line[0..len]);
    _ = c.close(pipefd[0]);
    if (!safe) _ = c.kill(pid, c.SIGKILL);
    var st: c_int = 0;
    while (c.waitpid(pid, &st, 0) < 0 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
    return safe and c.WIFEXITED(st) and c.WEXITSTATUS(st) == 0;
}

fn runArgv(argv: []const ?[*:0]const u8) bool {
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = c.execvp(argv[0].?, @ptrCast(@constCast(argv.ptr)));
        c._exit(127);
    }
    var st: c_int = 0;
    while (c.waitpid(pid, &st, 0) < 0 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
    return c.WIFEXITED(st) and c.WEXITSTATUS(st) == 0;
}

fn extIs(path: []const u8, exts: []const []const u8) bool {
    for (exts) |ext| if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    return false;
}

fn captureArgv(argv: []const ?[*:0]const u8, out: []u8) usize {
    var pipefd: [2]c_int = undefined;
    if (c.pipe(&pipefd) != 0) return 0;
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        return 0;
    }
    if (pid == 0) {
        _ = c.dup2(pipefd[1], 1);
        _ = c.dup2(pipefd[1], 2);
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        _ = c.execvp(argv[0].?, @ptrCast(@constCast(argv.ptr)));
        c._exit(127);
    }
    _ = c.close(pipefd[1]);
    var used: usize = 0;
    while (used < out.len) {
        const n = c.read(pipefd[0], out[used..].ptr, out.len - used);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        used += @intCast(n);
    }
    _ = c.close(pipefd[0]);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return if (c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0) used else 0;
}

// ── external probe fallbacks (ffprobe / pdfinfo) ─────────────────
//
// One path for both consumers: the preview job's media-info panel and
// the media_meta extractor's fallback for containers the pure-Zig
// parsers do not demux.

/// PATH lookup with an execute check. Both probes are optional on the
/// host, so a missing binary must degrade silently, never error.
fn binaryExists(name: []const u8) bool {
    const path_env = c.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, std.mem.span(@as([*:0]const u8, @ptrCast(path_env))), ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        var z: [4096:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&z, "{s}/{s}", .{ dir, name }) catch continue;
        if (c.access(p.ptr, c.X_OK) == 0) return true;
    }
    return false;
}

/// ffprobe entry selection used by the properties dialog's media info.
const FFPROBE_PREVIEW_ENTRIES = "format=duration:format_tags=title,artist,album";
/// Richer selection for media_meta: everything the key namespace maps.
const FFPROBE_META_ENTRIES = "format=duration,bit_rate:format_tags=title,artist,album,album_artist,date,track,genre,composer,comment:stream=codec_type,codec_name,width,height,sample_rate,channels";

fn ffprobeEntries(source: [*:0]const u8, entries: [*:0]const u8, out: []u8) usize {
    if (!binaryExists("ffprobe")) return 0;
    const argv = [_:null]?[*:0]const u8{
        "ffprobe", "-v",                         "error", "-show_entries", entries,
        "-of",     "default=noprint_wrappers=1", source,  null,
    };
    return captureArgv(&argv, out);
}

fn pdfinfoText(source: [*:0]const u8, out: []u8) usize {
    if (!binaryExists("pdfinfo")) return 0;
    const argv = [_:null]?[*:0]const u8{ "pdfinfo", source, null };
    return captureArgv(&argv, out);
}

fn rasterThumbnail(allocator: std.mem.Allocator, source: [:0]const u8, output: [:0]const u8, bound: c_int) bool {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = c.stbi_load(source.ptr, &width, &height, &channels, 4) orelse return false;
    defer c.stbi_image_free(pixels);
    if (width <= 0 or height <= 0) return false;
    const scale = @max(@as(f64, @floatFromInt(width)) / @as(f64, @floatFromInt(bound)), @as(f64, @floatFromInt(height)) / @as(f64, @floatFromInt(bound)));
    const out_w: c_int = if (scale > 1) @intFromFloat(@max(1.0, @as(f64, @floatFromInt(width)) / scale)) else width;
    const out_h: c_int = if (scale > 1) @intFromFloat(@max(1.0, @as(f64, @floatFromInt(height)) / scale)) else height;
    const src: [*]const u8 = @ptrCast(pixels);
    const rgba = src[0 .. @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4];
    if (out_w == width and out_h == height)
        return c.stbi_write_png(output.ptr, out_w, out_h, 4, rgba.ptr, out_w * 4) != 0;
    const scaled = png.downscaleRgba(
        allocator,
        rgba,
        @intCast(width),
        @intCast(height),
        @intCast(out_w),
        @intCast(out_h),
    ) catch return false;
    defer allocator.free(scaled);
    return c.stbi_write_png(output.ptr, out_w, out_h, 4, scaled.ptr, out_w * 4) != 0;
}

/// Must match the GUI's PREVIEW_IMAGE_CAP: reads refuse larger assets.
const TRANSPORT_BYTE_CAP: usize = 2 << 20;

const PngSink = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    failed: bool = false,
};

fn pngSinkWrite(ctx: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const sink: *PngSink = @ptrCast(@alignCast(ctx.?));
    if (sink.failed or size <= 0) return;
    const chunk = @as([*]const u8, @ptrCast(data.?))[0..@intCast(size)];
    sink.buf.appendSlice(sink.allocator, chunk) catch {
        sink.failed = true;
    };
}

/// A decoded, bound-scaled RGBA image with its backing storage.
const ScaledRgba = struct {
    rgba: []const u8,
    w: u32,
    h: u32,
    pixels: ?*anyopaque,
    scaled: ?[]u8,

    fn deinit(self: *const ScaledRgba, allocator: std.mem.Allocator) void {
        if (self.scaled) |b| allocator.free(b);
        if (self.pixels) |p| c.stbi_image_free(p);
    }
};

/// Decode `source_path` and scale it down to fit `bound` px.
fn loadScaledRgba(allocator: std.mem.Allocator, source_path: []const u8, bound: u32) ?ScaledRgba {
    var pz: [4096:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&pz, "{s}", .{source_path}) catch return null;
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = c.stbi_load(path.ptr, &width, &height, &channels, 4) orelse return null;
    var owned = true;
    defer if (owned) c.stbi_image_free(pixels);
    if (width <= 0 or height <= 0) return null;
    const max_dim = @max(width, height);
    const out_w: u32 = if (max_dim > bound)
        @intFromFloat(@max(1.0, @as(f64, @floatFromInt(width)) * @as(f64, @floatFromInt(bound)) / @as(f64, @floatFromInt(max_dim))))
    else
        @intCast(width);
    const out_h: u32 = if (max_dim > bound)
        @intFromFloat(@max(1.0, @as(f64, @floatFromInt(height)) * @as(f64, @floatFromInt(bound)) / @as(f64, @floatFromInt(max_dim))))
    else
        @intCast(height);
    const pixels_len = std.math.mul(usize, @intCast(width), @intCast(height)) catch return null;
    const src_len = std.math.mul(usize, pixels_len, 4) catch return null;
    const src = @as([*]const u8, @ptrCast(pixels))[0..src_len];
    const scaled: ?[]u8 = if (out_w != width or out_h != height)
        png.downscaleRgba(allocator, src, @intCast(width), @intCast(height), out_w, out_h) catch return null
    else
        null;
    owned = false;
    return .{
        .rgba = scaled orelse src,
        .w = out_w,
        .h = out_h,
        .pixels = pixels,
        .scaled = scaled,
    };
}

/// Transcode a host-local image into the receiver's best transport codec.
fn transportPreview(
    allocator: std.mem.Allocator,
    source_path: []const u8,
    codecs: []const u8,
    bound: u32,
    out_path: *[4096:0]u8,
) ?[]const u8 {
    if (codecs.len == 0) return null;
    const img = loadScaledRgba(allocator, source_path, bound) orelse return null;
    defer img.deinit(allocator);
    const rgba = img.rgba;
    const out_w = img.w;
    const out_h = img.h;
    // Prefer the compact codecs; PNG is the always-available last
    // resort (stb encoder is compiled in — a host without
    // libjxl/libwebp, or a static mux-portable whose dlopen can never
    // load them, still previews). A local receiver lists only "png",
    // so local previews keep skipping the transcode entirely.
    var png_sink = PngSink{ .allocator = allocator };
    defer png_sink.buf.deinit(allocator);
    var jx_bytes: ?[]u8 = null;
    defer if (jx_bytes) |b| allocator.free(b);
    var bytes: []const u8 = undefined;
    var ext: []const u8 = undefined;
    if (imagecodec.encodePreferred(allocator, rgba, out_w, out_h, codecs, TRANSPORT_BYTE_CAP)) |encoded| {
        jx_bytes = encoded.bytes;
        bytes = encoded.bytes;
        ext = switch (encoded.codec) {
            .jxl => "jxl",
            .webp => "webp",
        };
    } else |_| {
        if (!imagecodec.wanted(codecs, "png")) return null;
        if (c.stbi_write_png_to_func(&pngSinkWrite, @ptrCast(&png_sink), @intCast(out_w), @intCast(out_h), 4, rgba.ptr, @intCast(out_w * 4)) == 0 or
            png_sink.failed or png_sink.buf.items.len > TRANSPORT_BYTE_CAP) return null;
        bytes = png_sink.buf.items;
        ext = "png";
    }
    var random: [8]u8 = undefined;
    if (c.getentropy(&random, random.len) != 0) {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        std.mem.writeInt(u64, &random, (@as(u64, @intCast(c.getpid())) << 32) ^ @as(u32, @intCast(ts.tv_nsec)), .little);
    }
    const nonce = std.mem.readInt(u64, &random, .little);
    // Under /tmp (not next to the source): a daemon killed between
    // asset and cleanup would otherwise orphan sidecars permanently
    // inside the freedesktop thumbnail cache; /tmp dies at boot.
    const out = std.fmt.bufPrintZ(out_path, "/tmp/.sketerm-preview-{x}.{s}", .{ nonce, ext }) catch return null;
    const fd = c.open(out.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return null;
    var open = true;
    defer {
        if (open) {
            _ = c.close(fd);
            _ = c.unlink(out.ptr);
        }
    }
    // Register the exclusive pathname before writing so cancellation
    // cannot leave a partial sidecar once the daemon has seen it.
    emit(.{ .ev = "asset", .path = out });
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) return null;
        off += @intCast(n);
    }
    if (c.fsync(fd) != 0 or c.close(fd) != 0) return null;
    open = false;
    return out;
}

/// Resize/transcode a previewer-owned image without installing a cache entry.
fn runPreviewTransport(allocator: std.mem.Allocator, spec: Spec) u8 {
    var source_z: [4096:0]u8 = undefined;
    const source = std.fmt.bufPrintZ(&source_z, "{s}", .{spec.src}) catch return emitError("preview path too long");
    defer {
        if (spec.delete_source) _ = c.unlink(source.ptr);
    }
    var transport_buf: [4096:0]u8 = undefined;
    const transport = transportPreview(allocator, spec.src, spec.image_codecs, 512, &transport_buf) orelse
        return emitError("no accepted preview codec (jxl/webp/png) or output over the 2 MiB cap");
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = transport });
    return 0;
}

/// Cheap remote playback: transcode a video into a low-bitrate,
/// capped-width fragmented MP4 spool under /tmp, growing while the
/// viewer plays it. Registered as an `asset` (the daemon unlinks it once
/// the job dies or the client goes), and its path rides the first
/// progress event so the viewer can start reading before the encode is
/// done. ffmpeg runs in this helper's process group, so a client that
/// disconnects kills the encode with the helper.
fn runPreviewStream(spec: Spec) u8 {
    var source_z: [4096:0]u8 = undefined;
    const source = std.fmt.bufPrintZ(&source_z, "{s}", .{spec.src}) catch return emitError("preview path too long");
    var st: c.struct_stat = undefined;
    if (c.stat(source.ptr, &st) != 0) return emitErrno("preview stat");
    if (!binaryExists("ffmpeg")) return emitErrorKind("no_encoder", "ffmpeg is not installed on this host");
    var random: [8]u8 = undefined;
    if (c.getentropy(&random, random.len) != 0) {
        var ts: c.struct_timespec = undefined;
        _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
        std.mem.writeInt(u64, &random, (@as(u64, @intCast(c.getpid())) << 32) ^ @as(u32, @intCast(ts.tv_nsec)), .little);
    }
    var out_z: [4096:0]u8 = undefined;
    const out = std.fmt.bufPrintZ(&out_z, "/tmp/.sketerm-preview-{x}.mp4", .{std.mem.readInt(u64, &random, .little)}) catch
        return emitError("spool path too long");
    // Create it ourselves (exclusive, private) so the name is claimed
    // and registered before ffmpeg starts writing.
    const fd = c.open(out.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    if (fd < 0) return emitErrno("spool create");
    _ = c.close(fd);
    emit(.{ .ev = "asset", .path = out });
    // Duration up front (ffprobe, when present) so the viewer can show a
    // seekable timeline before the encode is anywhere near done.
    const duration_ms = probeDurationMs(source.ptr);
    // A time seek is a fresh job from `start_ms`: input seeking (-ss
    // before -i) lands on the keyframe at or before it, cheaply.
    var ss_buf: [32:0]u8 = undefined;
    const ss = std.fmt.bufPrintZ(&ss_buf, "{d}.{d:0>3}", .{ spec.start_ms / 1000, spec.start_ms % 1000 }) catch unreachable;
    const argv = [_:null]?[*:0]const u8{
        "ffmpeg",         "-nostdin",   "-y",              "-v",                     "error",
        "-ss",            ss.ptr,       "-i",              source.ptr,               "-map",
        "0:v:0",          "-map",
        "0:a:0?",         "-vf",        PREVIEW_STREAM_VF, "-c:v",                   "libx264",
        "-preset",        "ultrafast",  "-tune",           "zerolatency",            "-crf",
        "28",             "-maxrate",   "2500k",           "-bufsize",               "5000k",
        "-pix_fmt",       "yuv420p",    "-c:a",            "aac",                    "-b:a",
        "128k",           "-ac",        "2",               "-movflags",              "frag_keyframe+empty_moov+default_base_moof",
        "-f",             "mp4",        out.ptr,           null,
    };
    const pid = c.fork();
    if (pid < 0) {
        _ = c.unlink(out.ptr);
        return emitErrno("fork");
    }
    if (pid == 0) {
        _ = c.execvp(argv[0].?, @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    // The viewer starts reading here; every later progress event
    // repeats the path and reports the spool's growth.
    emit(.{ .ev = "progress", .path = out, .done = @as(u64, 0), .total = @as(u64, @intCast(st.st_size)), .duration_ms = duration_ms });
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, c.WNOHANG);
        if (rc == pid) break;
        if (rc < 0 and std.posix.errno(rc) != .INTR) {
            _ = c.kill(pid, c.SIGKILL);
            return emitErrno("waitpid");
        }
        var ts: c.struct_timespec = .{ .tv_sec = 0, .tv_nsec = 250 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
        var spool_st: c.struct_stat = undefined;
        const written: u64 = if (c.stat(out.ptr, &spool_st) == 0) @intCast(spool_st.st_size) else 0;
        emit(.{ .ev = "progress", .path = out, .done = written, .total = @as(u64, @intCast(st.st_size)), .duration_ms = duration_ms });
    }
    if (!(c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0)) return emitError("ffmpeg could not transcode this file");
    var spool_st: c.struct_stat = undefined;
    const written: u64 = if (c.stat(out.ptr, &spool_st) == 0) @intCast(spool_st.st_size) else 0;
    emit(.{ .ev = "done", .path = out, .done = written, .total = written });
    return 0;
}

/// Width capped at 1280 (never upscaled), height follows the aspect and
/// stays even for yuv420p.
const PREVIEW_STREAM_VF = "scale=w='min(1280,iw)':h=-2";

/// The container duration in ms via ffprobe; 0 when unknown (no
/// ffprobe, or a stream without one), which the viewer shows as an
/// unseekable timeline.
fn probeDurationMs(source: [*:0]const u8) u64 {
    var out: [512]u8 = undefined;
    const n = ffprobeEntries(source, "format=duration", &out);
    return parseDurationMs(out[0..n]);
}

/// "duration=83.456\n" -> 83456. Tolerates ffprobe's N/A and noise.
fn parseDurationMs(text: []const u8) u64 {
    const key = "duration=";
    const at = std.mem.indexOf(u8, text, key) orelse return 0;
    var rest = text[at + key.len ..];
    if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| rest = rest[0..nl];
    rest = std.mem.trim(u8, rest, " \t\r");
    const secs = std.fmt.parseFloat(f64, rest) catch return 0;
    if (!(secs > 0) or secs > 1e9) return 0;
    return @intFromFloat(secs * 1000.0);
}

test "parseDurationMs reads ffprobe output and rejects N/A" {
    try std.testing.expectEqual(@as(u64, 83456), parseDurationMs("duration=83.456\n"));
    try std.testing.expectEqual(@as(u64, 0), parseDurationMs("duration=N/A\n"));
    try std.testing.expectEqual(@as(u64, 0), parseDurationMs(""));
}

const image_exts = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".jxl", ".bmp", ".tif", ".tiff", ".ico", ".svg", ".avif", ".heic", ".heif" };
const pdf_exts = [_][]const u8{".pdf"};
const video_exts = @import("../filebrowser/paths.zig").video_exts;
const audio_exts = @import("../filebrowser/paths.zig").audio_exts;

/// This host's XDG cache root ("/tmp" as the last resort).
fn cacheRootDir(buf: []u8) []const u8 {
    if (c.getenv("XDG_CACHE_HOME")) |p|
        return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
    if (c.getenv("HOME")) |p|
        return std.fmt.bufPrint(buf, "{s}/.cache", .{std.mem.span(@as([*:0]const u8, @ptrCast(p)))}) catch "/tmp";
    return "/tmp";
}

/// True when `path` is a file with bytes in it.
fn fileHasBytes(path: [*:0]const u8) bool {
    var st: c.struct_stat = undefined;
    if (c.stat(path, &st) != 0) return false;
    return st.st_size > 0;
}

/// Grab a video's poster frame into `raw`, one second in.
///
/// ffmpeg exits 0 when a seek lands past the end of a short clip and
/// writes no output file at all, so success is decided by the OUTPUT,
/// not by the exit status; a missing frame retries from the start.
/// Retrying is cheaper than clamping the seek to a probed duration:
/// it costs a second ffmpeg only for the rare sub-second clip, where
/// a clamp would cost an ffprobe on every single video preview.
fn videoPosterPng(source: [:0]const u8, raw: [:0]const u8, vf: [:0]const u8) bool {
    const seek = [_:null]?[*:0]const u8{ "ffmpeg", "-y", "-v", "error", "-ss", "1", "-i", source.ptr, "-frames:v", "1", "-vf", vf.ptr, raw.ptr, null };
    if (runArgv(&seek) and fileHasBytes(raw.ptr)) return true;
    const start = [_:null]?[*:0]const u8{ "ffmpeg", "-y", "-v", "error", "-i", source.ptr, "-frames:v", "1", "-vf", vf.ptr, raw.ptr, null };
    return runArgv(&start) and fileHasBytes(raw.ptr);
}

/// Generate a raw (uninstalled) thumbnail PNG for `src_path` at
/// `raw`, bounded to `bound` px. @return false when no generator on
/// this host could produce it.
fn generateThumbPng(allocator: std.mem.Allocator, src_path: []const u8, source: [:0]const u8, raw: [:0]const u8, bound: c_int) bool {
    var generated = false;
    if (extIs(src_path, &image_exts)) {
        if (extIs(src_path, &[_][]const u8{".svg"})) {
            var size_buf: [16:0]u8 = undefined;
            const size = std.fmt.bufPrintZ(&size_buf, "{d}", .{bound}) catch unreachable;
            const argv = [_:null]?[*:0]const u8{ "rsvg-convert", "--keep-aspect-ratio", "-w", size.ptr, "-h", size.ptr, "-o", raw.ptr, source.ptr, null };
            generated = runArgv(&argv);
        } else {
            generated = rasterThumbnail(allocator, source, raw, bound);
            if (!generated) {
                var vf_buf: [64:0]u8 = undefined;
                const vf = std.fmt.bufPrintZ(&vf_buf, "scale={d}:{d}:force_original_aspect_ratio=decrease", .{ bound, bound }) catch return false;
                const argv = [_:null]?[*:0]const u8{ "ffmpeg", "-y", "-v", "error", "-i", source.ptr, "-frames:v", "1", "-vf", vf.ptr, raw.ptr, null };
                generated = runArgv(&argv);
            }
        }
    } else if (extIs(src_path, &pdf_exts)) {
        var prefix_buf: [4096:0]u8 = undefined;
        const prefix = std.fmt.bufPrintZ(&prefix_buf, "{s}.page", .{raw[0 .. raw.len - 4]}) catch return false;
        var scale_buf: [16:0]u8 = undefined;
        const scale = std.fmt.bufPrintZ(&scale_buf, "{d}", .{bound}) catch unreachable;
        const argv = [_:null]?[*:0]const u8{ "pdftoppm", "-f", "1", "-singlefile", "-scale-to", scale.ptr, "-png", source.ptr, prefix.ptr, null };
        generated = runArgv(&argv);
        if (generated) {
            var made: [4096:0]u8 = undefined;
            const mp = std.fmt.bufPrintZ(&made, "{s}.png", .{prefix}) catch return false;
            generated = c.rename(mp.ptr, raw.ptr) == 0;
        }
    } else {
        var vf_buf: [64:0]u8 = undefined;
        const vf = if (extIs(src_path, &video_exts))
            std.fmt.bufPrintZ(&vf_buf, "scale={d}:{d}:force_original_aspect_ratio=decrease", .{ bound, bound }) catch return false
        else
            std.fmt.bufPrintZ(&vf_buf, "showwavespic=s={d}x{d}", .{ bound, bound }) catch return false;
        if (extIs(src_path, &video_exts)) {
            generated = videoPosterPng(source, raw, vf);
        } else {
            const argv = [_:null]?[*:0]const u8{ "ffmpeg", "-y", "-v", "error", "-i", source.ptr, "-filter_complex", vf.ptr, "-frames:v", "1", raw.ptr, null };
            generated = runArgv(&argv);
        }
    }
    // Every generator above writes `raw`; a zero exit that produced no
    // file is a failure, and reporting it as success hands the caller a
    // path it cannot read.
    return generated and fileHasBytes(raw.ptr);
}

/// Encode a host-local image into the receiver's best NON-PNG codec.
/// Null = no codec library available (or unreadable source).
fn encodeWire(allocator: std.mem.Allocator, source_path: []const u8, codecs: []const u8, bound: u32) ?struct { bytes: []u8, ext: []const u8 } {
    const img = loadScaledRgba(allocator, source_path, bound) orelse return null;
    defer img.deinit(allocator);
    const encoded = imagecodec.encodePreferred(allocator, img.rgba, img.w, img.h, codecs, TRANSPORT_BYTE_CAP) catch return null;
    return .{ .bytes = encoded.bytes, .ext = switch (encoded.codec) {
        .jxl => "jxl",
        .webp => "webp",
    } };
}

/// Wire-cache file cap; at the typical 2-20KB per sidecar this is
/// tens of MB. Pruned oldest-install-first (ctime), only when over.
const WIRE_THUMB_CACHE_MAX = 4096;
const WIRE_THUMB_CACHE_SWEEP = 1024;

/// Serve (or build) the wire-cache thumbnail (128px) or preview
/// (512px, its own xl/ cache dir) for `spec.src`. Freshness = the
/// cache file's mtime equals the source's, stamped at install. Null
/// = no codec library — caller falls back to the legacy spec-PNG
/// path. Media metadata (ffprobe/pdfinfo) is computed per fetch,
/// exactly as the spec-PNG path always did on its cache hits.
fn runWireThumb(allocator: std.mem.Allocator, spec: Spec, thumbnail_only: bool, mtime_sec: i64, cache_root: []const u8) ?u8 {
    const tier: thumbs.Tier = if (thumbnail_only) .normal else .x_large;
    var source_z: [4096:0]u8 = undefined;
    const source = std.fmt.bufPrintZ(&source_z, "{s}", .{spec.src}) catch return emitError("preview path too long");
    var metadata: [2048]u8 = undefined;
    var metadata_len: usize = 0;
    if (!thumbnail_only) {
        if (extIs(spec.src, &video_exts) or extIs(spec.src, &audio_exts)) {
            metadata_len = ffprobeEntries(source.ptr, FFPROBE_PREVIEW_ENTRIES, &metadata);
        } else if (extIs(spec.src, &pdf_exts)) {
            metadata_len = pdfinfoText(source.ptr, &metadata);
        }
    }

    // Already cached in a codec the receiver decodes?
    var it = std.mem.splitScalar(u8, spec.image_codecs, ',');
    while (it.next()) |raw_codec| {
        const codec = std.mem.trim(u8, raw_codec, " ");
        if (codec.len == 0 or std.mem.eql(u8, codec, "png")) continue;
        var pbuf: [4096]u8 = undefined;
        const p = thumbs.wireThumbPath(cache_root, spec.src, tier, codec, &pbuf) orelse continue;
        var pz: [4096:0]u8 = undefined;
        const path = pathz.pathZ(&pz, p) catch continue;
        var st: c.struct_stat = undefined;
        if (c.stat(path, &st) != 0 or st.st_size <= 0) continue;
        const fts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
        if (@as(i64, fts.tv_sec) != mtime_sec) continue;
        emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = p, .keep = true, .text = metadata[0..metadata_len] });
        return 0;
    }

    // Encode source: a valid freedesktop PNG (this host's own cache,
    // or another file manager's) is read through; otherwise generate
    // a raw thumb that never gets installed as PNG.
    var final_buf: [4096]u8 = undefined;
    const final = thumbs.thumbPathTier(cache_root, spec.src, tier, &final_buf) orelse return emitError("thumbnail path too long");
    var uri_buf: [4096 * 3 + 8]u8 = undefined;
    const uri = thumbs.fileUri(spec.src, &uri_buf) orelse return emitError("thumbnail URI too long");
    var raw_buf: [4096:0]u8 = undefined;
    var raw: ?[:0]const u8 = null;
    defer if (raw) |r| {
        _ = c.unlink(r.ptr);
    };
    const enc_src: []const u8 = if (thumbs.validatePng(final, uri, mtime_sec)) final else blk: {
        const r = std.fmt.bufPrintZ(&raw_buf, "/tmp/.sketerm-thumbgen-{d}.png", .{c.getpid()}) catch return emitError("thumbnail path too long");
        if (!generateThumbPng(allocator, spec.src, source, r, if (thumbnail_only) 128 else 512))
            return emitError("preview generator unavailable or failed");
        raw = r;
        break :blk r;
    };
    const enc = encodeWire(allocator, enc_src, spec.image_codecs, 512) orelse return null;
    defer allocator.free(enc.bytes);

    // Install through the explicitly non-durable cache writer, then stamp
    // mtime with the SOURCE's so the hit check above is a plain stat compare.
    var dbuf: [4096]u8 = undefined;
    const dest = thumbs.wireThumbPath(cache_root, spec.src, tier, enc.ext, &dbuf) orelse return emitError("thumbnail path too long");
    pathz.makeParentDirs(dest) catch return emitError("cannot create wire thumb cache");
    if (std.fs.path.dirname(dest)) |dir| sweepWireThumbs(dir);
    atomicwrite.writeCacheFile(dest, enc.bytes, 0o600) catch |err|
        return emitError(@errorName(err));
    var dz: [4096:0]u8 = undefined;
    const destz = pathz.pathZ(&dz, dest) catch return emitError("thumbnail path too long");
    const tv = [2]c.struct_timeval{
        .{ .tv_sec = @intCast(mtime_sec), .tv_usec = 0 },
        .{ .tv_sec = @intCast(mtime_sec), .tv_usec = 0 },
    };
    _ = c.utimes(destz, &tv);
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = dest, .keep = true, .text = metadata[0..metadata_len] });
    return 0;
}

/// Prune the wire cache oldest-install-first (ctime — mtime carries
/// the SOURCE's stamp). Only counts when called, only prunes when
/// over the cap; generation is already the expensive path.
fn sweepWireThumbs(dir: []const u8) void {
    var dz: [4096:0]u8 = undefined;
    const dirz = pathz.pathZ(&dz, dir) catch return;
    const Item = struct { ctime: i64, name: [44]u8, name_len: usize };
    const a = std.heap.c_allocator;
    var items: std.ArrayList(Item) = .empty;
    defer items.deinit(a);
    const d = c.opendir(dirz) orelse return;
    defer _ = c.closedir(d);
    while (true) {
        const ent = c.readdir(d) orelse break;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&ent.*.d_name)));
        if (name.len < 5 or name.len > 44 or name[0] == '.') continue;
        var pz: [4200:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pz, "{s}/{s}", .{ dir, name }) catch continue;
        var st: c.struct_stat = undefined;
        if (c.stat(p.ptr, &st) != 0) continue;
        const cts = if (@hasField(c.struct_stat, "st_ctim")) st.st_ctim else st.st_ctimespec;
        var item = Item{ .ctime = cts.tv_sec, .name = undefined, .name_len = name.len };
        @memcpy(item.name[0..name.len], name);
        items.append(a, item) catch break;
        if (items.items.len >= WIRE_THUMB_CACHE_MAX * 2) break;
    }
    if (items.items.len <= WIRE_THUMB_CACHE_MAX) return;
    std.mem.sort(Item, items.items, {}, struct {
        fn lt(_: void, x: Item, y: Item) bool {
            return x.ctime < y.ctime;
        }
    }.lt);
    const doomed = @min(items.items.len - WIRE_THUMB_CACHE_MAX + WIRE_THUMB_CACHE_SWEEP, items.items.len);
    for (items.items[0..doomed]) |item| {
        var pz: [4200:0]u8 = undefined;
        const p = std.fmt.bufPrintZ(&pz, "{s}/{s}", .{ dir, item.name[0..item.name_len] }) catch continue;
        _ = c.unlink(p.ptr);
    }
}

fn runPreview(allocator: std.mem.Allocator, spec: Spec, thumbnail_only: bool) u8 {
    var source_z: [4096:0]u8 = undefined;
    const source = std.fmt.bufPrintZ(&source_z, "{s}", .{spec.src}) catch return emitError("preview path too long");
    var st: c.struct_stat = undefined;
    if (c.stat(source.ptr, &st) != 0) return emitErrno("preview stat");
    const ts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
    const mtime_sec: i64 = ts.tv_sec;
    const media = extIs(spec.src, &image_exts) or extIs(spec.src, &pdf_exts) or extIs(spec.src, &video_exts) or extIs(spec.src, &audio_exts);

    if (!media and !thumbnail_only) {
        const fp = c.fopen(source.ptr, "rb") orelse return emitErrno("preview open");
        var text: [4096]u8 = undefined;
        const n = c.fread(&text, 1, text.len, fp);
        _ = c.fclose(fp);
        if (std.mem.indexOfScalar(u8, text[0..n], 0) != null)
            emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .text = "(binary file)" })
        else
            emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .text = text[0..n] });
        return 0;
    }
    if (!media) return emitError("no thumbnailer for this file type");

    var cache_buf: [4096]u8 = undefined;
    const cache_root = cacheRootDir(&cache_buf);

    // Remote-serving wire cache (both tiers: 128px thumbnails and
    // 512px previews): the codec bytes themselves are the cache, no
    // freedesktop PNG is installed and no per-fetch re-encode
    // happens. Null = no codec library on this host — degrade to the
    // legacy spec-PNG path below.
    if (spec.wire_cache and spec.image_codecs.len > 0) {
        if (runWireThumb(allocator, spec, thumbnail_only, mtime_sec, cache_root)) |rc| return rc;
    }
    // Tier directories are size contracts other applications rely on:
    // normal is 128px, x-large is 512px. Writing a 512px image into
    // `large` (256px) would hand every other file manager an
    // out-of-spec entry it is entitled to trust.
    const tier: thumbs.Tier = if (thumbnail_only) .normal else .x_large;
    var final_buf: [4096]u8 = undefined;
    const final = thumbs.thumbPathTier(cache_root, spec.src, tier, &final_buf) orelse return emitError("thumbnail path too long");
    var uri_buf: [4096 * 3 + 8]u8 = undefined;
    const uri = thumbs.fileUri(spec.src, &uri_buf) orelse return emitError("thumbnail URI too long");
    const cached = thumbs.validatePng(final, uri, mtime_sec);
    if (!cached) {
        pathz.makeParentDirs(final) catch return emitError("cannot create thumbnail cache");
        var mode_buf: [4096]u8 = undefined;
        const thumb_dir = std.fmt.bufPrint(&mode_buf, "{s}/thumbnails", .{cache_root}) catch return emitError("cache path too long");
        var mode_z: [4096]u8 = undefined;
        _ = c.chmod(pathz.pathZ(&mode_z, thumb_dir) catch return emitError("cache path too long"), 0o700);
        const tier_dir = std.fs.path.dirname(final) orelse return emitError("bad thumbnail path");
        _ = c.chmod(pathz.pathZ(&mode_z, tier_dir) catch return emitError("cache path too long"), 0o700);
        var raw_buf: [4096:0]u8 = undefined;
        const raw = std.fmt.bufPrintZ(&raw_buf, "{s}.generated-{d}.png", .{ final, c.getpid() }) catch return emitError("thumbnail path too long");
        defer _ = c.unlink(raw.ptr);
        const bound: c_int = if (thumbnail_only) 128 else 512;
        if (!generateThumbPng(allocator, spec.src, source, raw, bound))
            return emitError("preview generator unavailable or failed");
        thumbs.installPng(allocator, raw, final, uri, mtime_sec) catch return emitError("cannot install thumbnail cache entry");
    }

    var metadata: [2048]u8 = undefined;
    var metadata_len: usize = 0;
    if (!thumbnail_only and (extIs(spec.src, &video_exts) or extIs(spec.src, &audio_exts))) {
        metadata_len = ffprobeEntries(source.ptr, FFPROBE_PREVIEW_ENTRIES, &metadata);
    } else if (!thumbnail_only and extIs(spec.src, &pdf_exts)) {
        metadata_len = pdfinfoText(source.ptr, &metadata);
    }
    var transport_buf: [4096:0]u8 = undefined;
    const transport = transportPreview(allocator, final, spec.image_codecs, 512, &transport_buf) orelse
        return emitError("no accepted preview codec (jxl/webp/png) or output over the 2 MiB cap");
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = transport, .text = metadata[0..metadata_len] });
    return 0;
}

/// Bytes of `git status` output read before the stream is cut. A
/// porcelain-v2 record is ~90 bytes, so this is room for ~11k of them
/// — an order of magnitude past the record caps below, which is what
/// decides what actually ships.
const GIT_STATUS_BYTES: usize = 1 << 20;
/// Records that describe a CHANGE (anything but `!`). Emitted first,
/// so a repository whose ignore rules match tens of thousands of
/// individual files loses ignored decoration and never a change.
const GIT_STATUS_CHANGES: u64 = 4096;
/// Total records, changes plus ignored.
const GIT_STATUS_RECORDS: u64 = 8192;

/// `git status --porcelain=v2 --branch --ignored -z` for the browsed
/// directory, run on the host that owns the repo.
///
/// Emits one `match` per record — `path` relative to the BROWSED dir
/// (the repo prefix is stripped here), `text` the 1-char aggregate
/// status a pre-v2 client understands, `xy` the two porcelain columns,
/// `orig` a rename source and `kind` "submodule" — then one `repo`
/// event carrying the branch header. A client too old to know those
/// fields ignores them and sees exactly the stream it always saw.
///
/// `--ignored` is unconditional because its default (`traditional`)
/// collapses a wholly ignored DIRECTORY into a single record: a
/// 50k-file `build/` costs one line, not 50k, so the cost is bounded
/// by the number of ignore rules that match rather than by the tree
/// they hide.
fn runGitStatus(allocator: std.mem.Allocator, spec: Spec) u8 {
    var cmd: [4400:0]u8 = undefined;
    var w = std.Io.Writer.fixed(cmd[0 .. cmd.len - 1]);
    w.writeAll("cd '") catch return emitError("path too long");
    for (spec.src) |ch| {
        if (ch == '\'') w.writeAll("'\\''") catch return emitError("path too long") else w.writeByte(ch) catch return emitError("path too long");
    }
    // \x01 closes the status stream, \x02 closes the prefix — and the
    // latter is only printed when rev-parse SUCCEEDED, which is the
    // "this is a repository" answer that survives a git too old for
    // porcelain v2 (its status output would be empty).
    w.print(
        "' 2>/dev/null && git status --porcelain=v2 --branch --ignored -z 2>/dev/null | head -c {d} && printf '\\x01' && git rev-parse --show-prefix 2>/dev/null && printf '\\x02'",
        .{GIT_STATUS_BYTES},
    ) catch return emitError("path too long");
    cmd[w.buffered().len] = 0;
    const fp = c.popen(&cmd, "r") orelse return emitError("cannot run git");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        out.appendSlice(allocator, buf[0..n]) catch break;
        if (out.items.len > GIT_STATUS_BYTES + 8192) break;
    }
    _ = c.pclose(fp);
    const sep = std.mem.indexOfScalar(u8, out.items, 1) orelse {
        // `cd` failed, or the shell never ran: not an error — "no
        // overlay" is a normal answer — but nothing is known either,
        // so no repo event is invented.
        emit(.{ .ev = "done", .done = @as(u64, 0), .total = @as(u64, 0) });
        return 0;
    };
    var status = out.items[0..sep];
    const tail = out.items[sep + 1 ..];
    const end = std.mem.indexOfScalar(u8, tail, 2);
    const prefix = std.mem.trim(u8, tail[0 .. end orelse tail.len], "\n ");
    // rev-parse succeeded: a repository, whatever the status said.
    const rev_parse_ok = end != null;

    var truncated = false;
    if (status.len > 0 and status[status.len - 1] != 0) {
        // `head -c` cut mid-record; drop the partial tail rather than
        // scanning garbage into a badge.
        truncated = true;
        status = if (std.mem.lastIndexOfScalar(u8, status, 0)) |last| status[0 .. last + 1] else status[0..0];
    }

    // Two passes so the caps spend themselves on changes first.
    var header = gitstatus.Header{};
    var emitted: u64 = 0;
    for ([_]bool{ false, true }) |ignored_pass| {
        var s = gitstatus.Scanner.init(status);
        while (s.next()) |rec| {
            if ((rec.kind == .ignored) != ignored_pass) continue;
            const cap = if (ignored_pass) GIT_STATUS_RECORDS else GIT_STATUS_CHANGES;
            if (emitted >= cap) {
                truncated = true;
                break;
            }
            const path = stripGitPrefix(rec.path, prefix) orelse continue;
            if (path.len == 0) continue;
            // JSON cannot carry a non-UTF-8 name; the listing that
            // would wear the badge cannot either.
            if (!std.unicode.utf8ValidateSlice(path)) {
                truncated = true;
                continue;
            }
            const orig = stripGitPrefix(rec.orig, prefix) orelse rec.orig;
            const xy = [2]u8{ rec.x, rec.y };
            emit(.{
                .ev = "match",
                .path = path,
                .text = &[1]u8{rec.legacyChar()},
                .xy = &xy,
                .orig = if (std.unicode.utf8ValidateSlice(orig)) orig else "",
                .kind = if (rec.submodule) "submodule" else "",
            });
            emitted += 1;
        }
        header = s.header;
    }

    // Last, so `truncated` is already known.
    emit(.{
        .ev = "repo",
        .repo = header.is_repo or rev_parse_ok,
        .branch = header.branch,
        .upstream = header.upstream,
        .text = header.oid[0..@min(header.oid.len, 8)],
        .ahead = header.ahead,
        .behind = header.behind,
        .have_ab = header.have_ab,
        .detached = header.detached,
        .initial = header.initial,
        .root = prefix.len == 0,
        .truncated = truncated,
    });
    emit(.{ .ev = "done", .done = emitted, .total = emitted });
    return 0;
}

/// Re-root one repository-relative path onto the browsed directory,
/// or null when it names something outside it.
fn stripGitPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (prefix.len == 0) return path;
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    return path[prefix.len..];
}

/// Bytes of `git diff` output read before the stream is cut. A file
/// whose diff against HEAD is larger than this is one nobody reads a
/// gutter on.
const GIT_DIFF_BYTES: usize = 1 << 20;
/// Cap on the RUNS one gutter answer carries. A run is a whole hunk
/// side, so this is thousands of hunks; past it the answer is marked
/// truncated rather than grown.
const GIT_DIFF_RUNS: u64 = 8192;

/// Per-line change marks for ONE file against HEAD, on the host that
/// owns the file.
///
/// `src` is the file's absolute path; the repository is whatever git
/// finds from its directory, so no client has to know a root. The
/// diff is parsed HERE (`editor/gitdiff.zig`, the same module the
/// editor folds the answer with) and what ships is one `line` event
/// per RUN of consecutive same-kind lines: `line` = 0-based start,
/// `size` = how many lines, `kind` = added/modified/deleted.
///
/// The `repo` event that closes the stream carries the three states a
/// gutter must tell apart and which no run can express: `repo` (the
/// file lives in a repository at all), `tracked` (git knows the file),
/// `initial` (a repository whose HEAD has no commit yet). Every "no"
/// answer here is a normal completion — a file outside a repository,
/// or a host without git, is not an error.
fn runGitDiff(allocator: std.mem.Allocator, spec: Spec) u8 {
    if (spec.src.len == 0) return emitError("git_diff needs a path");
    const dir = std.fs.path.dirname(spec.src) orelse "/";
    const base = std.fs.path.basename(spec.src);
    if (base.len == 0) return emitError("git_diff needs a file, not a directory");

    var cmd: [9000:0]u8 = undefined;
    var w = std.Io.Writer.fixed(cmd[0 .. cmd.len - 1]);
    const Q = struct {
        fn quote(wr: *std.Io.Writer, text: []const u8) !void {
            try wr.writeByte('\'');
            for (text) |ch| {
                if (ch == '\'') try wr.writeAll("'\\''") else try wr.writeByte(ch);
            }
            try wr.writeByte('\'');
        }
    };
    // \x01 = inside a repository, \x02 = HEAD resolves, \x03 = the
    // file is tracked. Each is printed only when its probe SUCCEEDED,
    // so a git too old for one of them simply withholds that flag
    // instead of poisoning the diff that follows.
    blk: {
        w.writeAll("cd ") catch break :blk;
        Q.quote(&w, dir) catch break :blk;
        w.writeAll(" 2>/dev/null || exit 0; git rev-parse --git-dir >/dev/null 2>&1 || exit 0; printf '\\001'; git rev-parse --verify HEAD >/dev/null 2>&1 && printf '\\002'; git ls-files --error-unmatch -- ") catch break :blk;
        Q.quote(&w, base) catch break :blk;
        w.writeAll(" >/dev/null 2>&1 && printf '\\003'; git diff -U0 --no-color --no-ext-diff HEAD -- ") catch break :blk;
        Q.quote(&w, base) catch break :blk;
        w.print(" 2>/dev/null | head -c {d}", .{GIT_DIFF_BYTES}) catch break :blk;
        cmd[w.buffered().len] = 0;

        const fp = c.popen(&cmd, "r") orelse return emitError("cannot run git");
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        var buf: [8192]u8 = undefined;
        var oom = false;
        while (true) {
            const n = c.fread(&buf, 1, buf.len, fp);
            if (n == 0) break;
            out.appendSlice(allocator, buf[0..n]) catch {
                oom = true;
                break;
            };
            if (out.items.len > GIT_DIFF_BYTES + 8192) break;
        }
        _ = c.pclose(fp);
        if (oom) return emitError("git diff too large");

        var i: usize = 0;
        var in_repo = false;
        var have_head = false;
        var tracked = false;
        while (i < out.items.len) : (i += 1) {
            switch (out.items[i]) {
                1 => in_repo = true,
                2 => have_head = true,
                3 => tracked = true,
                else => break,
            }
        }
        var text = out.items[i..];
        var truncated = false;
        if (text.len >= GIT_DIFF_BYTES) {
            // `head -c` cut mid-line; drop the partial tail so the
            // parser never reads half a hunk body.
            truncated = true;
            if (std.mem.lastIndexOfScalar(u8, text, '\n')) |last| text = text[0 .. last + 1];
        }

        const lines = gitdiff.parseUnified(allocator, text) catch return emitError("out of memory parsing diff");
        defer allocator.free(lines);
        const runs = gitdiff.runsFromLines(allocator, lines) catch return emitError("out of memory folding diff");
        defer allocator.free(runs);
        var emitted: u64 = 0;
        for (runs) |r| {
            if (emitted >= GIT_DIFF_RUNS) {
                truncated = true;
                break;
            }
            emit(.{
                .ev = "line",
                .line = @as(u64, r.line),
                .size = @as(u64, r.count),
                .kind = gitdiff.kindName(r.kind),
            });
            emitted += 1;
        }
        emit(.{
            .ev = "repo",
            .repo = in_repo,
            .tracked = tracked,
            .initial = in_repo and !have_head,
            .truncated = truncated,
        });
        emit(.{ .ev = "done", .done = emitted, .total = emitted });
        return 0;
    }
    return emitError("path too long");
}

/// `diff -u src dst` on this host, streamed as one `line` event per
/// diff line (bounded). Identical files complete with zero lines;
/// binary files get diff's own one-line verdict.
fn runDiff(allocator: std.mem.Allocator, spec: Spec) u8 {
    if (spec.dst.len == 0) return emitError("diff needs two paths");
    var cmd: [8600:0]u8 = undefined;
    var w = std.Io.Writer.fixed(cmd[0 .. cmd.len - 1]);
    w.writeAll("diff -u -- '") catch return emitError("path too long");
    for (spec.src) |ch| {
        if (ch == '\'') w.writeAll("'\\''") catch return emitError("path too long") else w.writeByte(ch) catch return emitError("path too long");
    }
    w.writeAll("' '") catch return emitError("path too long");
    for (spec.dst) |ch| {
        if (ch == '\'') w.writeAll("'\\''") catch return emitError("path too long") else w.writeByte(ch) catch return emitError("path too long");
    }
    w.writeAll("' 2>&1 | head -c 262144") catch return emitError("path too long");
    cmd[w.buffered().len] = 0;
    const fp = c.popen(&cmd, "r") orelse return emitError("cannot run diff");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        out.appendSlice(allocator, buf[0..n]) catch break;
        if (out.items.len > 300 * 1024) break;
    }
    _ = c.pclose(fp);
    var emitted: u64 = 0;
    var it = std.mem.splitScalar(u8, out.items, '\n');
    while (it.next()) |line| {
        if (emitted >= 4000) {
            emit(.{ .ev = "line", .line = emitted, .text = "[diff truncated]" });
            emitted += 1;
            break;
        }
        if (line.len == 0 and it.peek() == null) break;
        emit(.{ .ev = "line", .line = emitted, .text = line[0..@min(line.len, 2048)] });
        emitted += 1;
    }
    emit(.{ .ev = "done", .done = emitted, .total = emitted });
    return 0;
}

/// "10M"/"1G"/plain bytes → bytes; null on junk or zero.
fn parsePartSize(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var digits = s;
    var mult: u64 = 1;
    switch (s[s.len - 1]) {
        'k', 'K' => {
            mult = 1 << 10;
            digits = s[0 .. s.len - 1];
        },
        'm', 'M' => {
            mult = 1 << 20;
            digits = s[0 .. s.len - 1];
        },
        'g', 'G' => {
            mult = 1 << 30;
            digits = s[0 .. s.len - 1];
        },
        else => {},
    }
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
    if (n == 0) return null;
    return std.math.mul(u64, n, mult) catch null;
}

/// Split `src` into `<src>.001`, `.002`, … of `pattern` bytes each
/// (TC convention). Existing part files refuse the whole job rather
/// than silently overwriting a previous split.
fn runSplit(spec: Spec) u8 {
    const part_size = parsePartSize(spec.pattern) orelse return emitError("bad part size");
    var sz: [4096:0]u8 = undefined;
    const src = pathz.pathZ(&sz, spec.src) catch return emitError("path too long");
    var st: c.struct_stat = undefined;
    if (c.lstat(src, &st) != 0) return emitErrno("split stat");
    if (st.st_mode & c.S_IFMT != c.S_IFREG) return emitError("split needs a regular file");
    const total: u64 = @intCast(st.st_size);
    const parts = if (total == 0) 1 else (total + part_size - 1) / part_size;
    if (parts > 999) return emitError("more than 999 parts; pick a larger part size");
    const in = c.open(src, c.O_RDONLY | c.O_CLOEXEC);
    if (in < 0) return emitErrno("split open");
    defer _ = c.close(in);
    var done: u64 = 0;
    var part: u32 = 1;
    while (part <= parts) : (part += 1) {
        var pz: [4200:0]u8 = undefined;
        const pp = std.fmt.bufPrintZ(&pz, "{s}.{d:0>3}", .{ spec.src, part }) catch return emitError("path too long");
        const out = c.open(pp.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, st.st_mode & 0o777);
        if (out < 0) return emitErrno("split part exists or unwritable");
        defer _ = c.close(out);
        var remain: u64 = @min(part_size, total - done);
        var buf: [1 << 16]u8 = undefined;
        while (remain > 0) {
            const want: usize = @intCast(@min(remain, buf.len));
            const n = c.read(in, &buf, want);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n <= 0) return emitError("split read failed");
            var off: usize = 0;
            while (off < @as(usize, @intCast(n))) {
                const w = c.write(out, buf[off..].ptr, @as(usize, @intCast(n)) - off);
                if (w < 0 and std.posix.errno(w) == .INTR) continue;
                if (w <= 0) return emitError("split write failed");
                off += @intCast(w);
            }
            remain -= @intCast(n);
            done += @intCast(n);
            emit(.{ .ev = "progress", .done = done, .total = total });
        }
        if (c.fsync(out) != 0) return emitErrno("split fsync");
    }
    emit(.{ .ev = "done", .done = total, .total = total });
    return 0;
}

/// Rebuild `<base>` from `<base>.001`… (any first-part path may be
/// given). The destination must not exist yet.
fn runCombine(spec: Spec) u8 {
    // Strip a trailing ".NNN" to find the base name.
    const dot = std.mem.lastIndexOfScalar(u8, spec.src, '.') orelse return emitError("not a split part");
    const ext = spec.src[dot + 1 ..];
    if (ext.len != 3) return emitError("not a .NNN split part");
    _ = std.fmt.parseInt(u16, ext, 10) catch return emitError("not a .NNN split part");
    const base = spec.src[0..dot];
    var dz: [4096:0]u8 = undefined;
    const dst = pathz.pathZ(&dz, base) catch return emitError("path too long");
    const out = c.open(dst, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o644));
    if (out < 0) return emitErrno("combine destination exists or unwritable");
    var ok = false;
    defer {
        _ = c.close(out);
        if (!ok) _ = c.unlink(dst);
    }
    var part: u32 = 1;
    var done: u64 = 0;
    while (part <= 999) : (part += 1) {
        var pz: [4200:0]u8 = undefined;
        const pp = std.fmt.bufPrintZ(&pz, "{s}.{d:0>3}", .{ base, part }) catch return emitError("path too long");
        const in = c.open(pp.ptr, c.O_RDONLY | c.O_CLOEXEC);
        if (in < 0) {
            if (part == 1) return emitError("no .001 part beside the file");
            break;
        }
        defer _ = c.close(in);
        var buf: [1 << 16]u8 = undefined;
        while (true) {
            const n = c.read(in, &buf, buf.len);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n < 0) return emitError("combine read failed");
            if (n == 0) break;
            var off: usize = 0;
            while (off < @as(usize, @intCast(n))) {
                const w = c.write(out, buf[off..].ptr, @as(usize, @intCast(n)) - off);
                if (w < 0 and std.posix.errno(w) == .INTR) continue;
                if (w <= 0) return emitError("combine write failed");
                off += @intCast(w);
            }
            done += @intCast(n);
        }
        emit(.{ .ev = "progress", .done = done, .total = @as(u64, 0) });
    }
    if (c.fsync(out) != 0) return emitErrno("combine fsync");
    ok = true;
    emit(.{ .ev = "done", .done = done, .total = done, .path = base });
    return 0;
}

/// One random overwrite pass + fsync + unlink. Regular files only —
/// and honesty demands saying so: on CoW/journaled filesystems the
/// old extents may survive; this is best-effort, like every GUI
/// shredder.
fn runSecureDelete(spec: Spec) u8 {
    var sz: [4096:0]u8 = undefined;
    const src = pathz.pathZ(&sz, spec.src) catch return emitError("path too long");
    var st: c.struct_stat = undefined;
    if (c.lstat(src, &st) != 0) return emitErrno("stat");
    if (st.st_mode & c.S_IFMT != c.S_IFREG) return emitError("secure delete works on regular files only");
    const total: u64 = @intCast(st.st_size);
    const fd = c.open(src, c.O_WRONLY | c.O_CLOEXEC);
    if (fd < 0) return emitErrno("open");
    var closed = false;
    defer if (!closed) {
        _ = c.close(fd);
    };
    // Cheap PRNG stream seeded from real entropy: getentropy per
    // block would cap throughput far below the disk.
    var seed: [8]u8 = undefined;
    if (c.getentropy(&seed, seed.len) != 0) std.mem.writeInt(u64, &seed, @as(u64, @intCast(c.getpid())) ^ total, .little);
    var state = std.mem.readInt(u64, &seed, .little) | 1;
    var buf: [1 << 16]u8 = undefined;
    var done: u64 = 0;
    while (done < total) {
        var i: usize = 0;
        while (i + 8 <= buf.len) : (i += 8) {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            std.mem.writeInt(u64, buf[i..][0..8], state, .little);
        }
        const want: usize = @intCast(@min(total - done, buf.len));
        var off: usize = 0;
        while (off < want) {
            const w = c.write(fd, buf[off..].ptr, want - off);
            if (w < 0 and std.posix.errno(w) == .INTR) continue;
            if (w <= 0) return emitError("overwrite failed");
            off += @intCast(w);
        }
        done += want;
        emit(.{ .ev = "progress", .done = done, .total = total });
    }
    if (c.fsync(fd) != 0) return emitErrno("fsync");
    _ = c.close(fd);
    closed = true;
    if (c.unlink(src) != 0) return emitErrno("unlink");
    emit(.{ .ev = "done", .done = total, .total = total });
    return 0;
}

fn runExtract(spec: Spec) u8 {
    if (spec.dst.len == 0) return emitError("extract needs destination directory");
    if (!archiveMembersSafe(spec.src)) return emitError("archive is unreadable or contains unsafe paths");
    var dz: [4096]u8 = undefined;
    const dp = pathz.pathZ(&dz, spec.dst) catch return emitError("destination path too long");
    if (c.mkdir(dp, 0o755) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST)
        return emitErrno("mkdir destination");
    var az: [4096:0]u8 = undefined;
    const ap = std.fmt.bufPrintZ(&az, "{s}", .{spec.src}) catch return emitError("archive path too long");
    emit(.{ .ev = "progress", .done = @as(u64, 0), .total = @as(u64, 0) });
    const argv = [_:null]?[*:0]const u8{
        "bsdtar", "-xf", ap.ptr, "-C", dp, "--no-same-owner", "--safe-writes", null,
    };
    if (!runArgv(&argv)) return emitError("archive extraction failed (bsdtar required)");
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1) });
    return 0;
}

/// Stream an archive's member list as match events (bsdtar handles
/// tar/tar.*/zip/7z alike). Only the member table crosses the wire.
fn runArchiveList(spec: Spec) u8 {
    var az: [4096:0]u8 = undefined;
    const ap = std.fmt.bufPrintZ(&az, "{s}", .{spec.src}) catch return emitError("archive path too long");
    var pipefd: [2]c_int = undefined;
    if (c.pipe(&pipefd) != 0) return emitErrno("pipe");
    const pid = c.fork();
    if (pid < 0) return emitErrno("fork");
    if (pid == 0) {
        _ = c.dup2(pipefd[1], 1);
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        const argv = [_:null]?[*:0]const u8{ "bsdtar", "-tf", ap.ptr, null };
        _ = c.execvp("bsdtar", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.close(pipefd[1]);
    var line: [4096]u8 = undefined;
    var len: usize = 0;
    var matches: u64 = 0;
    var truncated = false;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(pipefd[0], &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        for (buf[0..@intCast(n)]) |ch| {
            if (ch == '\n') {
                if (len > 0 and matches < MAX_MATCHES) {
                    const member = line[0..len];
                    const is_dir = member[member.len - 1] == '/';
                    emit(.{
                        .ev = "match",
                        .path = if (is_dir) member[0 .. member.len - 1] else member,
                        .kind = if (is_dir) "dir" else "file",
                        .size = @as(u64, 0),
                    });
                    matches += 1;
                } else if (len > 0) {
                    truncated = true;
                }
                len = 0;
            } else if (len < line.len) {
                line[len] = ch;
                len += 1;
            }
        }
    }
    _ = c.close(pipefd[0]);
    var wstatus: c_int = 0;
    _ = c.waitpid(pid, &wstatus, 0);
    if (matches == 0 and (wstatus != 0)) return emitError("cannot list archive (bsdtar required)");
    emit(.{ .ev = "done", .done = matches, .total = matches, .matches = matches, .truncated = truncated });
    return 0;
}

/// Extract ONE member host-side (into `dst`, or a fresh private tmp
/// dir) and report the extracted path in the done event.
fn runArchiveExtractMember(spec: Spec) u8 {
    const member = spec.pattern;
    if (member.len == 0) return emitError("archive_extract needs a member");
    if (unsafeArchiveMember(member)) return emitError("unsafe archive member path");
    var dir_buf: [4096]u8 = undefined;
    var dir: []const u8 = undefined;
    if (spec.dst.len > 0) {
        dir = spec.dst;
        var dz: [4096]u8 = undefined;
        const dp = pathz.pathZ(&dz, dir) catch return emitError("destination too long");
        if (c.mkdir(dp, 0o755) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST)
            return emitErrno("mkdir destination");
    } else {
        const tmpl = "/tmp/sketerm-arx-XXXXXX";
        @memcpy(dir_buf[0..tmpl.len], tmpl);
        dir_buf[tmpl.len] = 0;
        const made = c.mkdtemp(@ptrCast(&dir_buf)) orelse return emitErrno("mkdtemp");
        dir = std.mem.span(@as([*:0]u8, @ptrCast(made)));
    }
    var az: [4096:0]u8 = undefined;
    const ap = std.fmt.bufPrintZ(&az, "{s}", .{spec.src}) catch return emitError("archive path too long");
    var dz2: [4096:0]u8 = undefined;
    const dp2 = std.fmt.bufPrintZ(&dz2, "{s}", .{dir}) catch return emitError("destination too long");
    var mz: [4096:0]u8 = undefined;
    const mp = std.fmt.bufPrintZ(&mz, "{s}", .{member}) catch return emitError("member too long");
    const argv = [_:null]?[*:0]const u8{
        "bsdtar", "-xf", ap.ptr, "-C", dp2.ptr, "--no-same-owner", "--safe-writes", mp.ptr, null,
    };
    if (!runArgv(&argv)) return emitError("member extraction failed (bsdtar required)");
    var out_buf: [4096]u8 = undefined;
    const out = std.fmt.bufPrint(&out_buf, "{s}/{s}", .{ dir, member }) catch return emitError("path too long");
    var st: c.struct_stat = undefined;
    if (!statOf(out, &st, false)) return emitError("member not found after extraction");
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = out });
    return 0;
}

fn runArchiveCreate(spec: Spec) u8 {
    if (spec.dst.len == 0) return emitError("archive_create needs destination archive");
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return emitErrno("stat source");
    const parent = std.fs.path.dirname(spec.src) orelse "/";
    const base = std.fs.path.basename(spec.src);
    var pz: [4096:0]u8 = undefined;
    var bz: [4096:0]u8 = undefined;
    var dz: [4096:0]u8 = undefined;
    const pp = std.fmt.bufPrintZ(&pz, "{s}", .{parent}) catch return emitError("source path too long");
    const bp = std.fmt.bufPrintZ(&bz, "{s}", .{base}) catch return emitError("source path too long");
    const dp = std.fmt.bufPrintZ(&dz, "{s}", .{spec.dst}) catch return emitError("archive path too long");
    emit(.{ .ev = "progress", .done = @as(u64, 0), .total = @as(u64, 0) });
    const argv = [_:null]?[*:0]const u8{ "bsdtar", "-caf", dp.ptr, "-C", pp.ptr, bp.ptr, null };
    if (!runArgv(&argv)) return emitError("archive creation failed (bsdtar required or format unsupported)");
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1) });
    return 0;
}

// ── freedesktop trash ────────────────────────────────────────────

fn trashRoot(buf: []u8) ?[]const u8 {
    if (c.getenv("XDG_DATA_HOME")) |p| {
        const base = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        return std.fmt.bufPrint(buf, "{s}/Trash", .{base}) catch null;
    }
    const homep = c.getenv("HOME") orelse return null;
    const home = std.mem.span(@as([*:0]const u8, @ptrCast(homep)));
    return std.fmt.bufPrint(buf, "{s}/.local/share/Trash", .{home}) catch null;
}

fn ensureTrashDirs(root: []const u8) bool {
    var files: [4096]u8 = undefined;
    var info: [4096]u8 = undefined;
    const fp = std.fmt.bufPrint(&files, "{s}/files", .{root}) catch return false;
    const ip = std.fmt.bufPrint(&info, "{s}/info", .{root}) catch return false;
    pathz.makeParentDirs(fp) catch return false;
    var z: [4096]u8 = undefined;
    const rz = pathz.pathZ(&z, root) catch return false;
    if (c.mkdir(rz, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) return false;
    const fz = pathz.pathZ(&z, fp) catch return false;
    if (c.mkdir(fz, 0o700) != 0 and std.posix.errno(@as(c_int, -1)) != .EXIST) return false;
    const iz = pathz.pathZ(&z, ip) catch return false;
    return c.mkdir(iz, 0o700) == 0 or std.posix.errno(@as(c_int, -1)) == .EXIST;
}

fn appendUrlEscaped(w: *std.Io.Writer, path: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (path) |ch| {
        if (std.ascii.isAlphanumeric(ch) or ch == '/' or ch == '-' or ch == '_' or ch == '.' or ch == '~') {
            try w.writeByte(ch);
        } else {
            try w.writeByte('%');
            try w.writeByte(hex[ch >> 4]);
            try w.writeByte(hex[ch & 15]);
        }
    }
}

fn deletionStamp(buf: *[32]u8) []const u8 {
    var now: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&now, &tm);
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}", .{
        tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec,
    }) catch "1970-01-01T00:00:00";
}

fn runTrash(spec: Spec) u8 {
    if (spec.src.len <= 1) return emitError("refusing to trash root");
    var root_buf: [4096]u8 = undefined;
    const home_root = trashRoot(&root_buf) orelse return emitError("cannot locate trash directory");
    switch (trashInto(spec.src, home_root)) {
        .ok => return 0,
        .fail => return emitErrno("move to trash"),
        .xdev => {},
    }
    // Different filesystem: freedesktop $topdir/.Trash-$uid fallback.
    var mp_buf: [4096]u8 = undefined;
    const mp = deviceMountpoint(spec.src, &mp_buf) orelse return emitError("move to trash: cross-device and no mountpoint found");
    var top_buf: [4096]u8 = undefined;
    const top_root = std.fmt.bufPrint(&top_buf, "{s}/.Trash-{d}", .{
        if (mp.len == 1) "" else mp, c.getuid(),
    }) catch return emitError("trash path too long");
    return switch (trashInto(spec.src, top_root)) {
        .ok => 0,
        else => emitErrno("move to trash (topdir)"),
    };
}

const TrashResult = enum { ok, xdev, fail };

/// One trash attempt into `root` (files/ + info/ created as needed).
/// Emits the done event itself on success.
fn trashInto(src: []const u8, root: []const u8) TrashResult {
    if (!ensureTrashDirs(root)) return .fail;
    const base = std.fs.path.basename(src);
    var name_buf: [512]u8 = undefined;
    var files_buf: [4096]u8 = undefined;
    var info_buf: [4096]u8 = undefined;
    var attempt: u32 = 0;
    var trashed: []const u8 = undefined;
    var info_path: []const u8 = undefined;
    while (attempt < 10000) : (attempt += 1) {
        const name = if (attempt == 0)
            std.fmt.bufPrint(&name_buf, "{s}", .{base}) catch return .fail
        else
            std.fmt.bufPrint(&name_buf, "{s}.{d}", .{ base, attempt }) catch return .fail;
        trashed = std.fmt.bufPrint(&files_buf, "{s}/files/{s}", .{ root, name }) catch return .fail;
        info_path = std.fmt.bufPrint(&info_buf, "{s}/info/{s}.trashinfo", .{ root, name }) catch return .fail;
        var z: [4096]u8 = undefined;
        var st: c.struct_stat = undefined;
        if (c.lstat(pathz.pathZ(&z, trashed) catch return .fail, &st) != 0 and
            std.posix.errno(@as(c_int, -1)) == .NOENT) break;
    }
    if (attempt == 10000) return .fail;

    var text: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&text);
    w.writeAll("[Trash Info]\nPath=") catch return .fail;
    appendUrlEscaped(&w, src) catch return .fail;
    var stamp_buf: [32]u8 = undefined;
    w.print("\nDeletionDate={s}\n", .{deletionStamp(&stamp_buf)}) catch return .fail;
    var iz: [4096]u8 = undefined;
    const ip = pathz.pathZ(&iz, info_path) catch return .fail;
    const info = c.fopen(ip, "wx") orelse return .fail;
    if (c.fwrite(w.buffered().ptr, 1, w.buffered().len, info) != w.buffered().len or c.fclose(info) != 0) {
        _ = c.unlink(ip);
        return .fail;
    }
    var sz: [4096]u8 = undefined;
    var tz: [4096]u8 = undefined;
    if (c.rename(pathz.pathZ(&sz, src) catch return .fail, pathz.pathZ(&tz, trashed) catch return .fail) != 0) {
        const failed_errno = std.posix.errno(@as(c_int, -1));
        _ = c.unlink(ip);
        return if (failed_errno == .XDEV) .xdev else .fail;
    }
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1), .path = trashed, .text = info_path });
    return .ok;
}

/// The mountpoint holding `path`: walk parents until st_dev changes.
fn deviceMountpoint(path: []const u8, buf: []u8) ?[]const u8 {
    var st: c.struct_stat = undefined;
    if (!statOf(path, &st, false)) return null;
    const dev = st.st_dev;
    var cur_buf: [4096]u8 = undefined;
    var cur: []const u8 = std.fs.path.dirname(path) orelse "/";
    if (cur.len > cur_buf.len) return null;
    @memcpy(cur_buf[0..cur.len], cur);
    cur = cur_buf[0..cur.len];
    while (cur.len > 1) {
        const parent = std.fs.path.dirname(cur) orelse "/";
        var pst: c.struct_stat = undefined;
        if (!statOf(parent, &pst, false)) break;
        if (pst.st_dev != dev) break;
        const plen = parent.len;
        std.mem.copyForwards(u8, cur_buf[0..plen], parent);
        cur = cur_buf[0..plen];
    }
    if (cur.len > buf.len) return null;
    @memcpy(buf[0..cur.len], cur);
    return buf[0..cur.len];
}

fn runTrashRestore(spec: Spec) u8 {
    if (spec.dst.len == 0) return emitError("trash_restore needs original destination");
    pathz.makeParentDirs(spec.dst) catch return emitError("cannot create restore parent");
    var sz: [4096]u8 = undefined;
    var dz: [4096]u8 = undefined;
    if (c.rename(pathz.pathZ(&sz, spec.src) catch return emitError("path too long"), pathz.pathZ(&dz, spec.dst) catch return emitError("path too long")) != 0)
        return emitErrno("restore from trash");
    if (spec.pattern.len > 0) {
        var iz: [4096]u8 = undefined;
        _ = c.unlink(pathz.pathZ(&iz, spec.pattern) catch return emitError("trash info path too long"));
    }
    emit(.{ .ev = "done", .done = @as(u64, 1), .total = @as(u64, 1) });
    return 0;
}

// ── durable cross-host copy coordinator ──────────────────────────

fn connectHostFs(allocator: std.mem.Allocator, host: []const u8) !fsdrive.Fs {
    const conn = if (host.len == 0)
        try muxclient.Conn.connectLocalAutostart(allocator)
    else blk: {
        // The daemon host's own config governs its outbound UDP;
        // journal-resumed jobs read the CURRENT value, not a stale
        // copy journaled at submission time.
        var cfg = @import("../config.zig").Config.load(allocator);
        defer cfg.deinit();
        break :blk try muxclient.Conn.connectRemote(allocator, host, cfg.udpRange());
    };
    return fsdrive.Fs.initConn(allocator, conn);
}

/// Is this failure the LINK dying rather than the filesystem refusing?
/// Only that class is worth reconnecting for; a permission error or a
/// full disk will answer the same way forever.
fn isTransportError(err: fsdrive.Error) bool {
    return err == fsdrive.Error.Timeout or err == fsdrive.Error.NotConnected;
}

fn needsCleanupRetry(move: bool, retryable_transport: bool, phase: []const u8) bool {
    return move and retryable_transport and
        fsjournal.phaseRank(phase) >= fsjournal.phaseRank("copied");
}

fn moveDeletionStarted(delete_src: bool, phase: []const u8) bool {
    return delete_src and fsjournal.phaseRank(phase) >= fsjournal.phaseRank("deleting");
}

/// The one cancellation probe: sticky once seen, and never true after
/// the deletion boundary (cancel can no longer restore the source).
fn durableCancelRequested(journal_dir: []const u8, job_id: u64) bool {
    if (durable_state.delete_started) return false;
    if (durable_state.cancel_requested) return true;
    if (job_id == 0 or journal_dir.len == 0) return false;
    durable_state.cancel_requested = fsjournal.cancelRequested(journal_dir, job_id);
    return durable_state.cancel_requested;
}

const CLEANUP_RECONNECT_BACKOFF_MS = [_]u32{ 5_000, 10_000, 20_000 };

/// Reconnect budget for ONE cross-host copy attempt. A multi-GB
/// transfer over a home link legitimately outlives several drops, so
/// the ceiling is generous; it exists only so a permanently dead host
/// ends the attempt instead of spinning on it forever. Exhaustion
/// fails with kind "transport", so the client ledger's own retry
/// policy still applies on top.
const RECONNECT_ATTEMPTS: u32 = 6;
const RECONNECT_BUDGET: u32 = 200;
const RECONNECT_BACKOFF_MS = [_]u32{ 1_000, 2_000, 4_000, 8_000, 15_000, 30_000 };

const Side = enum {
    src,
    dst,

    fn label(self: Side) []const u8 {
        return switch (self) {
            .src => "source",
            .dst => "destination",
        };
    }
};

const CrossCopy = struct {
    allocator: std.mem.Allocator,
    src: *fsdrive.Fs,
    dst: *fsdrive.Fs,
    journal_dir: []const u8 = "",
    job_id: u64 = 0,
    /// Host strings the two sides were opened with, so a dropped link
    /// can be dialled again.
    src_host: []const u8,
    dst_host: []const u8,
    no_replace: bool = false,
    progress: Progress = .{},
    /// Why the copy stopped. Empty until something fails; the error
    /// line reports it verbatim, because "cross-host copy failed" told
    /// a user with a half-transferred 3 GB file exactly nothing.
    fail_buf: [320]u8 = undefined,
    fail_len: usize = 0,
    /// Reconnects spent so far, across every file in the job.
    reconnects: u32 = 0,
    retryable_transport: bool = false,
    /// Set while a reconnect is being reported, so the notice reaches
    /// the panel on the next progress line.
    notice_buf: [160]u8 = undefined,
    notice_len: usize = 0,
    /// This job is a MOVE — drives the "copy already installed" note
    /// on failures past the copied boundary.
    move: bool = false,
    /// Content digests proven THIS run, keyed on stat identity. ctime
    /// deliberately participates: an in-place edit with restored mtime
    /// must never authorize deletion through a stale digest, and ctime
    /// is the one timestamp such an edit cannot forge. Our OWN
    /// quarantine/install renames also bump ctime without touching
    /// content; hashRefreshAfterRename restamps the entry there, so
    /// the guard costs no multi-GB rehash at those boundaries.
    hash_seen: std.ArrayList(HashSeen) = .empty,

    const HashSeen = struct {
        side: Side,
        dev: u64,
        ino: u64,
        size: u64,
        mtime_ns: i64,
        ctime_ns: i64,
        digest: [64]u8,

        fn matches(self: HashSeen, side: Side, e: fsdrive.Entry) bool {
            return self.side == side and self.dev == e.dev and self.ino == e.ino and
                self.size == e.size and self.mtime_ns == e.mtime_ns and self.ctime_ns == e.ctime_ns;
        }
    };
    /// Cache cap: a tree larger than this restarts the cache rather
    /// than growing without bound (the verify passes walk in the same
    /// order, so even a thrashing cache still covers the big files).
    const HASH_SEEN_MAX: usize = 1024;

    fn deinitCaches(self: *CrossCopy) void {
        self.hash_seen.deinit(self.allocator);
    }

    fn canceled(self: *CrossCopy) bool {
        return durableCancelRequested(self.journal_dir, self.job_id);
    }

    /// hash() through the per-run digest cache. Trust level: a cache
    /// hit means the inode, size and both change timestamps still match.
    fn hashCached(self: *CrossCopy, side: Side, path: []const u8) ?[64]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const before = self.fail_len;
        const e = self.statProbe(side, arena.allocator(), path) orelse {
            self.fail_len = before;
            return self.hash(side, path);
        };
        if (!std.mem.eql(u8, e.kind, "file")) return self.hash(side, path);
        for (self.hash_seen.items) |*seen| {
            if (seen.matches(side, e)) return seen.digest;
        }
        const digest = self.hash(side, path) orelse return null;
        self.hashRemember(side, e, &digest);
        return digest;
    }

    /// After WE renamed `path`, adopt its fresh ctime into any cached
    /// digest for the same inode. A rename changes only ctime; every
    /// other identity drift means someone else touched the file, and
    /// the entry is dropped so the next use rehashes. Best effort with
    /// no reconnect: it can run under the control lock, and a skipped
    /// restamp only costs a rehash later.
    fn hashRefreshAfterRename(self: *CrossCopy, side: Side, path: []const u8) void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const e = self.fsOf(side).statPath(arena.allocator(), path) catch return;
        if (!std.mem.eql(u8, e.kind, "file")) return;
        hashRestampRenamed(&self.hash_seen, side, e);
    }

    fn hashRestampRenamed(list: *std.ArrayList(HashSeen), side: Side, e: fsdrive.Entry) void {
        var i: usize = 0;
        while (i < list.items.len) {
            const seen = &list.items[i];
            if (seen.side != side or seen.dev != e.dev or seen.ino != e.ino) {
                i += 1;
            } else if (seen.size == e.size and seen.mtime_ns == e.mtime_ns) {
                seen.ctime_ns = e.ctime_ns;
                i += 1;
            } else {
                _ = list.swapRemove(i);
            }
        }
    }

    fn hashRemember(self: *CrossCopy, side: Side, e: fsdrive.Entry, digest: *const [64]u8) void {
        if (self.hash_seen.items.len >= HASH_SEEN_MAX) self.hash_seen.clearRetainingCapacity();
        self.hash_seen.append(self.allocator, .{
            .side = side,
            .dev = e.dev,
            .ino = e.ino,
            .size = e.size,
            .mtime_ns = e.mtime_ns,
            .ctime_ns = e.ctime_ns,
            .digest = digest.*,
        }) catch {};
    }

    fn fsOf(self: *CrossCopy, side: Side) *fsdrive.Fs {
        return switch (side) {
            .src => self.src,
            .dst => self.dst,
        };
    }

    fn hostOf(self: *CrossCopy, side: Side) []const u8 {
        return switch (side) {
            .src => self.src_host,
            .dst => self.dst_host,
        };
    }

    fn hostLabel(self: *CrossCopy, side: Side) []const u8 {
        const h = self.hostOf(side);
        return if (h.len == 0) "local" else h;
    }

    /// Record the first failure; later ones are consequences of it.
    fn fail(self: *CrossCopy, comptime fmt: []const u8, args: anytype) void {
        if (self.fail_len > 0) return;
        var w = std.Io.Writer.fixed(&self.fail_buf);
        w.print(fmt, args) catch {};
        self.fail_len = w.buffered().len;
    }

    fn failOp(self: *CrossCopy, side: Side, what: []const u8, path: []const u8, err: fsdrive.Error) void {
        const detail = self.fsOf(side).lastErr();
        if (err == fsdrive.Error.FsOpFailed and detail.len > 0) {
            self.fail("{s} {s} on {s}: {s}", .{
                what,
                tailOf(path),
                self.hostLabel(side),
                @import("../filebrowser/format.zig").errorPhrase(detail),
            });
        } else {
            self.fail("{s} {s} on {s}: {s}", .{ what, tailOf(path), self.hostLabel(side), @errorName(err) });
        }
    }

    fn failedReason(self: *const CrossCopy) []const u8 {
        if (self.fail_len == 0) return "cross-host copy failed";
        return self.fail_buf[0..self.fail_len];
    }

    fn emitFailure(self: *const CrossCopy) u8 {
        const phase = durable_state.progress.phase.slice();
        _ = durableCancelRequested(self.journal_dir, self.job_id);
        if (durable_state.cancel_requested and fsjournal.phaseRank(phase) < fsjournal.phaseRank("deleting")) {
            return cancelCleanupRetry("cancel requested; resolving the durable source state");
        }
        if (needsCleanupRetry(self.move, self.retryable_transport, phase)) {
            return cancelCleanupRetry(self.failedReason());
        }
        if (self.move and fsjournal.phaseRank(phase) >= fsjournal.phaseRank("copied")) {
            // Past "copied" the destination is verified and installed
            // under its final name; only source cleanup remains. A bare
            // "failed" here reads as data loss, which it is not.
            var buf: [400]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            w.print("the copy is complete and installed; {s}", .{self.failedReason()}) catch
                return emitError(self.failedReason());
            return emitErrorKind(if (self.retryable_transport) "transport" else "permanent", w.buffered());
        }
        return emitErrorKind(if (self.retryable_transport) "transport" else "permanent", self.failedReason());
    }

    /// Emit a progress line carrying a human note. The daemon keeps the
    /// last message on the job, so the panel shows "reconnecting…"
    /// while it happens instead of a row that silently stalls.
    fn notice(self: *CrossCopy, comptime fmt: []const u8, args: anytype) void {
        var w = std.Io.Writer.fixed(&self.notice_buf);
        w.print(fmt, args) catch {};
        self.notice_len = w.buffered().len;
        emit(.{
            .ev = "progress",
            .done = self.progress.done,
            .total = self.progress.total,
            .resumed_from = self.progress.resumed,
            .message = self.notice_buf[0..self.notice_len],
            .files_done = self.progress.entries_done,
            .files_total = self.progress.entries_total,
        });
    }

    /// Shared failure policy of every remote call in the copy: a
    /// transport error reconnects that side and asks the caller to try
    /// the same operation again; anything else records the reason and
    /// ends the job.
    /// @return true when the operation should be retried.
    fn recoverOrFail(self: *CrossCopy, side: Side, what: []const u8, path: []const u8, err: fsdrive.Error) bool {
        if (!isTransportError(err)) {
            self.failOp(side, what, path, err);
            return false;
        }
        return self.reconnect(side);
    }

    /// Re-establish ONE side's connection. The transfer itself needs no
    /// other repair: every read and write names an explicit offset, and
    /// the staged `.skpart` on the destination already holds everything
    /// acknowledged so far. Giving up marks the attempt retryable, so
    /// the client ledger's transport policy takes over.
    fn reconnect(self: *CrossCopy, side: Side) bool {
        if (self.reconnects >= RECONNECT_BUDGET) {
            self.retryable_transport = true;
            self.fail("{s} host {s} kept dropping ({d} reconnects)", .{
                side.label(), self.hostLabel(side), self.reconnects,
            });
            return false;
        }
        var attempt: u32 = 0;
        while (attempt < RECONNECT_ATTEMPTS) : (attempt += 1) {
            // A cancel request must not wait out up to a minute of
            // backoff; the retryable failure routes it to recovery.
            if (self.canceled()) break;
            self.reconnects += 1;
            const wait_ms = RECONNECT_BACKOFF_MS[@min(attempt, RECONNECT_BACKOFF_MS.len - 1)];
            self.notice("{s} {s} unreachable -- reconnecting in {d}s (attempt {d}/{d})", .{
                side.label(), self.hostLabel(side), wait_ms / 1000, attempt + 1, RECONNECT_ATTEMPTS,
            });
            sleepMs(wait_ms);
            const fresh = connectHostFs(self.allocator, self.hostOf(side)) catch continue;
            const fs = self.fsOf(side);
            fs.deinit();
            fs.* = fresh;
            self.notice("reconnected to {s}; resuming at {d} MB", .{
                self.hostLabel(side), self.progress.done >> 20,
            });
            return true;
        }
        self.retryable_transport = true;
        self.fail("cannot reconnect to {s} host {s}", .{ side.label(), self.hostLabel(side) });
        return false;
    }

    /// Ranged read that survives a dropped link.
    fn readChunk(self: *CrossCopy, path: []const u8, off: u64, want: u32, out: *std.ArrayList(u8)) bool {
        while (true) {
            out.clearRetainingCapacity();
            _ = self.src.read(path, off, want, out) catch |err| {
                if (!self.recoverOrFail(.src, "read", path, err)) return false;
                continue;
            };
            if (out.items.len == 0) {
                self.fail("read {s} on {s}: short read at offset {d}", .{
                    tailOf(path), self.hostLabel(.src), off,
                });
                return false;
            }
            return true;
        }
    }

    /// Offset-addressed write that survives a dropped link. Replaying
    /// the same offset after a reconnect is idempotent, so a write that
    /// half-landed before the drop costs nothing.
    fn writeChunk(self: *CrossCopy, path: []const u8, off: u64, data: []const u8, flags: fsdrive.WriteFlags) bool {
        while (true) {
            const written = self.dst.write(path, off, data, flags) catch |err| {
                if (!self.recoverOrFail(.dst, "write", path, err)) return false;
                continue;
            };
            if (written != data.len) {
                self.fail("write {s} on {s}: {d} of {d} bytes accepted", .{
                    tailOf(path), self.hostLabel(.dst), written, data.len,
                });
                return false;
            }
            return true;
        }
    }

    /// stat whose "not there" is an ordinary answer (the resume probes
    /// and the metadata copy), so it records no failure reason. A dead
    /// link still reconnects rather than reading as absence.
    fn statProbe(self: *CrossCopy, side: Side, arena: std.mem.Allocator, path: []const u8) ?fsdrive.Entry {
        while (true) {
            return self.fsOf(side).statPath(arena, path) catch |err| {
                if (!isTransportError(err)) return null;
                if (!self.reconnect(side)) return null;
                continue;
            };
        }
    }

    /// stat the job cannot continue without: its failure IS the job's.
    fn statRequired(self: *CrossCopy, side: Side, arena: std.mem.Allocator, path: []const u8) ?fsdrive.Entry {
        while (true) {
            return self.fsOf(side).statPath(arena, path) catch |err| {
                if (!self.recoverOrFail(side, "stat", path, err)) return null;
                continue;
            };
        }
    }

    fn hash(self: *CrossCopy, side: Side, path: []const u8) ?[64]u8 {
        while (true) {
            const fs = self.fsOf(side);
            const job = fs.startHash(path) catch |err| {
                if (!self.recoverOrFail(side, "hash", path, err)) return null;
                continue;
            };
            const end = fs.waitJobEnd(job, 120_000) catch |err| {
                if (!self.recoverOrFail(side, "hash", path, err)) return null;
                continue;
            };
            if (!end.ok or !end.has_hash) {
                self.fail("hash {s} on {s}: {s}", .{
                    tailOf(path),                                                               self.hostLabel(side),
                    if (end.messageText().len > 0) end.messageText() else "no digest returned",
                });
                return null;
            }
            return end.hash;
        }
    }

    fn copyFile(self: *CrossCopy, src_path: []const u8, dst_path: []const u8, size: u64, allow_resume: bool, no_replace: bool) bool {
        self.progress.setFile(src_path);
        if (allow_resume and !no_replace) {
            var arena_final = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_final.deinit();
            if (self.statProbe(.dst, arena_final.allocator(), dst_path)) |e| {
                if (std.mem.eql(u8, e.kind, "file") and e.size == size) {
                    // A destination that already matches is the whole
                    // point of resume; a digest that cannot be taken
                    // just means "copy it again", never a job failure.
                    const before = self.fail_len;
                    const sh = self.hashCached(.src, src_path);
                    const dh = self.hashCached(.dst, dst_path);
                    if (sh != null and dh != null and std.mem.eql(u8, &sh.?, &dh.?)) {
                        self.fail_len = before;
                        self.progress.resumed = std.math.add(u64, self.progress.resumed, size) catch {
                            self.fail("progress overflow while copying {s}", .{tailOf(dst_path)});
                            return false;
                        };
                        if (!self.progress.add(size) or !self.progress.entryDone()) {
                            self.fail("progress overflow while copying {s}", .{tailOf(dst_path)});
                            return false;
                        }
                        return true;
                    }
                    self.fail_len = before;
                }
            }
        }
        var part_buf: [4096]u8 = undefined;
        const part = std.fmt.bufPrint(&part_buf, "{s}.skpart", .{dst_path}) catch {
            self.fail("destination path too long: {s}", .{tailOf(dst_path)});
            return false;
        };
        var off: u64 = 0;
        if (allow_resume) {
            var arena_part = std.heap.ArenaAllocator.init(self.allocator);
            defer arena_part.deinit();
            if (self.statProbe(.dst, arena_part.allocator(), part)) |e| {
                if (std.mem.eql(u8, e.kind, "file") and e.size <= size) off = e.size;
            }
        }
        const resumed_from = off;
        self.progress.done = std.math.add(u64, self.progress.done, off) catch {
            self.fail("progress overflow while copying {s}", .{tailOf(dst_path)});
            return false;
        };
        self.progress.resumed = std.math.add(u64, self.progress.resumed, off) catch {
            self.fail("progress overflow while copying {s}", .{tailOf(dst_path)});
            return false;
        };
        self.progress.emitNow();
        if (size > 0 and !self.transferBytes(src_path, part, size, off)) return false;
        if (size == 0) {
            if (!self.writeChunk(part, 0, &.{}, .{ .create = true, .truncate = true })) return false;
        }
        if (!self.simpleDst("fsync", part, fsdrive.Fs.fsync)) return false;
        const sh = self.hashCached(.src, src_path) orelse return false;
        const dh = self.hashCached(.dst, part) orelse return false;
        if (!std.mem.eql(u8, &sh, &dh)) {
            self.dst.deletePath(part) catch {};
            if (resumed_from > 0) {
                // The staged prefix did not belong to this source after
                // all. Start it over from zero rather than fail.
                self.progress.done -|= size;
                self.progress.resumed -|= resumed_from;
                self.notice("staged partial for {s} did not verify -- restarting the file", .{tailOf(dst_path)});
                return self.copyFile(src_path, dst_path, size, false, no_replace);
            }
            self.fail("{s}: checksum mismatch after transfer", .{tailOf(dst_path)});
            return false;
        }
        // Verification precedes replacement: a corrupt transfer can
        // never destroy the destination that existed before this job.
        if (!self.renameDstClaimed(part, dst_path, no_replace, &dh, size)) {
            if (no_replace) self.dst.deletePath(part) catch {};
            return false;
        }
        var arena_meta = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_meta.deinit();
        if (self.statProbe(.src, arena_meta.allocator(), src_path)) |e| {
            self.dst.chmod(dst_path, e.mode) catch {};
            self.dst.utimens(dst_path, e.atime_ms, e.mtime_ms) catch {};
        }
        // utimens moved the destination's mtime off the cached
        // identity: rebind the proven digest to what a later verify
        // pass will stat, so it does not reread the whole file.
        _ = arena_meta.reset(.retain_capacity);
        if (self.statProbe(.dst, arena_meta.allocator(), dst_path)) |e| {
            if (std.mem.eql(u8, e.kind, "file") and e.size == size)
                self.hashRemember(.dst, e, &dh);
        }
        if (!self.progress.entryDone()) {
            self.fail("file-count overflow while copying {s}", .{tailOf(dst_path)});
            return false;
        }
        return true;
    }

    const Chunk = struct {
        start: u64,
        len: u32,
        filled: u32 = 0,
        req: u32 = 0,
        buf: std.ArrayList(u8) = .empty,
    };

    /// Chunks in flight per side. The old loop was strict stop-and-wait
    /// (one chunk per source round trip, then one per destination round
    /// trip), which capped WAN throughput at chunk-size/RTT and never
    /// overlapped disk reads with the network. Memory cost per file:
    /// XFER_WINDOW read buffers.
    const XFER_WINDOW: usize = 4;
    const XFER_CHUNK: u32 = @min(fsserve.MAX_READ, 1 << 20);

    /// Move [resume_off, size) of src_path into the staged partial with
    /// a bounded pipeline on both sides. Progress counts a chunk when
    /// its WRITE is acknowledged; a reconnect on either side restarts
    /// the window from the acknowledged contiguous prefix (offset
    /// writes are idempotent, so redoing an unacknowledged chunk is
    /// safe).
    fn transferBytes(self: *CrossCopy, src_path: []const u8, part: []const u8, size: u64, resume_off: u64) bool {
        const InFlightWrite = struct { req: u32, len: u32, end: u64 };
        var off = resume_off;
        restart: while (true) {
            var next = off;
            var reads: std.ArrayList(Chunk) = .empty;
            var writes: std.ArrayList(InFlightWrite) = .empty;
            var unacked_bytes: u64 = 0;
            var failed_side: ?Side = null;
            defer {
                for (reads.items) |*chunk| chunk.buf.deinit(self.allocator);
                reads.deinit(self.allocator);
                writes.deinit(self.allocator);
            }
            engine: while (true) {
                if (self.canceled()) return false;
                while (reads.items.len < XFER_WINDOW and next < size) {
                    const want: u32 = @intCast(@min(@as(u64, XFER_CHUNK), size - next));
                    const req = self.src.readSubmit(src_path, next, want) catch |err| {
                        if (!isTransportError(err)) {
                            self.failOp(.src, "read", src_path, err);
                            return false;
                        }
                        failed_side = .src;
                        break :engine;
                    };
                    reads.append(self.allocator, Chunk{ .start = next, .len = want, .req = req }) catch {
                        self.fail("out of memory while copying {s}", .{tailOf(src_path)});
                        return false;
                    };
                    next += want;
                }
                if (reads.items.len == 0 and writes.items.len == 0) return true;
                if (reads.items.len > 0) {
                    // Oldest chunk first: the daemon answers in order,
                    // so awaiting out of order would gain nothing.
                    const chunk = &reads.items[0];
                    while (chunk.filled < chunk.len) {
                        var p = self.src.awaitSubmitted(chunk.req, fsdrive.OP_TIMEOUT_MS) catch |err| {
                            if (!isTransportError(err)) {
                                self.failOp(.src, "read", src_path, err);
                                return false;
                            }
                            failed_side = .src;
                            break :engine;
                        };
                        defer p.data.deinit(self.allocator);
                        if (p.data.items.len == 0) {
                            self.fail("read {s} on {s}: short read at offset {d}", .{
                                tailOf(src_path), self.hostLabel(.src), chunk.start + chunk.filled,
                            });
                            return false;
                        }
                        chunk.buf.appendSlice(self.allocator, p.data.items) catch {
                            self.fail("out of memory while copying {s}", .{tailOf(src_path)});
                            return false;
                        };
                        chunk.filled += @intCast(p.data.items.len);
                        if (chunk.filled < chunk.len) {
                            // Short mid-file read: fetch the remainder
                            // before this chunk may be written.
                            chunk.req = self.src.readSubmit(src_path, chunk.start + chunk.filled, chunk.len - chunk.filled) catch |err| {
                                if (!isTransportError(err)) {
                                    self.failOp(.src, "read", src_path, err);
                                    return false;
                                }
                                failed_side = .src;
                                break :engine;
                            };
                        }
                    }
                    const wreq = self.dst.writeSubmit(part, chunk.start, chunk.buf.items, .{
                        .create = true,
                        .truncate = chunk.start == 0 and resume_off == 0,
                    }) catch |err| {
                        if (!isTransportError(err)) {
                            self.failOp(.dst, "write", part, err);
                            return false;
                        }
                        failed_side = .dst;
                        break :engine;
                    };
                    writes.append(self.allocator, .{ .req = wreq, .len = chunk.len, .end = chunk.start + chunk.len }) catch {
                        self.fail("out of memory while copying {s}", .{tailOf(src_path)});
                        return false;
                    };
                    unacked_bytes += chunk.len;
                    var sent = reads.orderedRemove(0);
                    sent.buf.deinit(self.allocator);
                }
                if (writes.items.len >= XFER_WINDOW or (reads.items.len == 0 and next >= size and writes.items.len > 0)) {
                    const w = writes.orderedRemove(0);
                    const idle = fsdrive.OP_TIMEOUT_MS + fsdrive.uploadBudgetMs(unacked_bytes);
                    const p = self.dst.awaitSubmitted(w.req, idle) catch |err| {
                        if (!isTransportError(err)) {
                            self.failOp(.dst, "write", part, err);
                            return false;
                        }
                        failed_side = .dst;
                        break :engine;
                    };
                    unacked_bytes -= w.len;
                    if (p.written != w.len) {
                        self.fail("write {s} on {s}: {d} of {d} bytes accepted", .{
                            tailOf(part), self.hostLabel(.dst), p.written, w.len,
                        });
                        return false;
                    }
                    // FIFO awaits keep this contiguous: everything up
                    // to w.end is acknowledged on the destination.
                    off = w.end;
                    if (!self.progress.add(w.len)) {
                        self.fail("progress overflow while copying {s}", .{tailOf(part)});
                        return false;
                    }
                }
            }
            // A link died. Everything in flight is void; the staged
            // partial holds the acknowledged prefix, so the window
            // restarts there after the reconnect.
            self.src.cancelSubmitted();
            self.dst.cancelSubmitted();
            if (!self.reconnect(failed_side.?)) return false;
            continue :restart;
        }
    }

    /// renameDst that disambiguates a lost acknowledgment: when a
    /// retried rename answers EXIST or NOENT but the staged file is
    /// gone and the destination carries the verified digest, the first
    /// attempt committed and only its reply died. no_replace stays
    /// collision-safe — nothing but our own proven bytes is claimed.
    fn renameDstClaimed(self: *CrossCopy, from: []const u8, to: []const u8, no_replace: bool, expected: *const [64]u8, size: u64) bool {
        while (true) {
            const result = if (no_replace) self.dst.renameNoReplace(from, to) else self.dst.rename(from, to);
            result catch |err| {
                if (isTransportError(err)) {
                    if (!self.reconnect(.dst)) return false;
                    if (self.renameCommitted(from, to, expected, size)) return true;
                    continue;
                }
                const detail = self.dst.lastErr();
                if (err == fsdrive.Error.FsOpFailed and
                    (std.mem.indexOf(u8, detail, "EXIST") != null or noEntDetail(detail)) and
                    self.renameCommitted(from, to, expected, size)) return true;
                self.failOp(.dst, "rename", to, err);
                return false;
            };
            // No digest restamp here: copyFile rebinds the proven
            // digest after its utimens anyway.
            return true;
        }
    }

    fn renameCommitted(self: *CrossCopy, from: []const u8, to: []const u8, expected: *const [64]u8, size: u64) bool {
        const before = self.fail_len;
        defer self.fail_len = before;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        if (self.statProbe(.dst, arena.allocator(), from) != null) return false;
        const final = self.statProbe(.dst, arena.allocator(), to) orelse return false;
        if (!std.mem.eql(u8, final.kind, "file") or final.size != size) return false;
        const dh = self.hashCached(.dst, to) orelse return false;
        return std.mem.eql(u8, &dh, expected);
    }

    /// A no-argument destination verb (fsync) with the same
    /// reconnect-and-retry treatment as the byte path.
    fn simpleDst(
        self: *CrossCopy,
        what: []const u8,
        path: []const u8,
        comptime call: fn (*fsdrive.Fs, []const u8) fsdrive.Error!void,
    ) bool {
        while (true) {
            call(self.dst, path) catch |err| {
                if (!self.recoverOrFail(.dst, what, path, err)) return false;
                continue;
            };
            return true;
        }
    }

    fn renameDst(self: *CrossCopy, from: []const u8, to: []const u8, no_replace: bool) bool {
        while (true) {
            const result = if (no_replace) self.dst.renameNoReplace(from, to) else self.dst.rename(from, to);
            result catch |err| {
                if (!self.recoverOrFail(.dst, "rename", to, err)) return false;
                continue;
            };
            return true;
        }
    }

    fn mkdirDst(self: *CrossCopy, path: []const u8) bool {
        while (true) {
            self.dst.mkdir(path) catch |err| {
                if (err == fsdrive.Error.FsOpFailed and
                    std.mem.indexOf(u8, self.dst.lastErr(), "EXIST") != null)
                {
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const existing = self.statProbe(.dst, arena.allocator(), path) orelse {
                        self.fail("cannot inspect existing destination directory {s}", .{tailOf(path)});
                        return false;
                    };
                    if (std.mem.eql(u8, existing.kind, "dir")) return true;
                    self.fail("destination path is not a directory: {s}", .{tailOf(path)});
                    return false;
                }
                if (!self.recoverOrFail(.dst, "mkdir", path, err)) return false;
                continue;
            };
            return true;
        }
    }

    fn listSide(self: *CrossCopy, side: Side, path: []const u8) ?fsdrive.Listing {
        while (true) {
            return self.fsOf(side).list(path) catch |err| {
                if (!self.recoverOrFail(side, "list", path, err)) return null;
                continue;
            };
        }
    }

    fn symlinkDst(self: *CrossCopy, target: []const u8, path: []const u8) bool {
        while (true) {
            self.dst.symlink(target, path) catch |err| {
                if (!self.recoverOrFail(.dst, "symlink", path, err)) return false;
                continue;
            };
            return true;
        }
    }

    const RenameMove = enum { moved, copy_fallback, failed };

    /// Same-host moves keep rename's atomic fast path. XDEV and
    /// destination collisions fall through to verified copy/delete;
    /// every other refusal remains an error rather than being hidden.
    fn tryRenameMove(self: *CrossCopy, src_path: []const u8, dst_path: []const u8, durable: CrossDurable) RenameMove {
        while (true) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const dst_current = self.statProbe(.src, arena.allocator(), dst_path);
            const src_current = self.statProbe(.src, arena.allocator(), src_path);
            if (src_current) |current| {
                if (!durableMatchesRoot(durable, current)) {
                    if (dst_current) |dest| {
                        if (durableMatchesRoot(durable, dest)) return .moved;
                    }
                    self.fail("same-host move source was replaced; retained it: {s}", .{tailOf(src_path)});
                    return .failed;
                }
            } else {
                if (dst_current) |dest| {
                    if (durableMatchesRoot(durable, dest)) return .moved;
                }
                self.fail("cannot resolve same-host move source identity: {s}", .{tailOf(src_path)});
                return .failed;
            }
            const result = if (self.no_replace) self.src.renameNoReplace(src_path, dst_path) else self.src.rename(src_path, dst_path);
            result catch |err| {
                if (isTransportError(err)) {
                    if (!self.reconnect(.src)) return .failed;
                    continue;
                }
                const detail = self.src.lastErr();
                if (err == fsdrive.Error.FsOpFailed and
                    (std.mem.indexOf(u8, detail, "XDEV") != null or
                        std.mem.indexOf(u8, detail, "EXIST") != null or
                        std.mem.indexOf(u8, detail, "NOTEMPTY") != null or
                        std.mem.indexOf(u8, detail, "ISDIR") != null))
                    return .copy_fallback;
                self.failOp(.src, "rename", src_path, err);
                return .failed;
            };
            return .moved;
        }
    }

    const ManifestKind = enum { file, dir, link, other };

    const ManifestItem = struct {
        rel: []u8,
        kind: ManifestKind,
        size: u64,
        mode: u32,
        mtime_ns: i64,
        ctime_ns: i64,
        dev: u64,
        ino: u64,
        atime_ms: i64,
        mtime_ms: i64,
        target: []u8,

        fn deinit(self: *ManifestItem, allocator: std.mem.Allocator) void {
            allocator.free(self.rel);
            allocator.free(self.target);
        }

        fn matches(self: *const ManifestItem, e: fsdrive.Entry) bool {
            if (self.kind != manifestKind(e.kind) or self.mode != e.mode or self.dev != e.dev or
                self.ino != e.ino or self.mtime_ns != e.mtime_ns or
                (self.rel.len != 0 and self.ctime_ns != e.ctime_ns))
                return false;
            if (self.kind == .file and self.size != e.size) return false;
            if (self.kind == .link)
                return std.mem.eql(u8, self.target, e.target orelse "");
            return true;
        }
    };

    const Manifest = struct {
        allocator: std.mem.Allocator,
        items: std.ArrayList(ManifestItem) = .empty,
        total: u64 = 0,
        files: u64 = 0,

        fn deinit(self: *Manifest) void {
            for (self.items.items) |*item| item.deinit(self.allocator);
            self.items.deinit(self.allocator);
        }

        fn sort(self: *Manifest) void {
            std.mem.sort(ManifestItem, self.items.items, {}, struct {
                fn lessThan(_: void, a: ManifestItem, b: ManifestItem) bool {
                    return std.mem.lessThan(u8, a.rel, b.rel);
                }
            }.lessThan);
        }

        fn append(self: *Manifest, rel: []const u8, e: fsdrive.Entry) !void {
            const rel_owned = try self.allocator.dupe(u8, rel);
            errdefer self.allocator.free(rel_owned);
            const target_owned = try self.allocator.dupe(u8, e.target orelse "");
            errdefer self.allocator.free(target_owned);
            const kind = manifestKind(e.kind);
            if (kind == .file) {
                self.total = try std.math.add(u64, self.total, e.size);
                self.files = try std.math.add(u64, self.files, 1);
            }
            try self.items.append(self.allocator, .{
                .rel = rel_owned,
                .kind = kind,
                .size = e.size,
                .mode = e.mode,
                .mtime_ns = e.mtime_ns,
                .ctime_ns = e.ctime_ns,
                .dev = e.dev,
                .ino = e.ino,
                .atime_ms = e.atime_ms,
                .mtime_ms = e.mtime_ms,
                .target = target_owned,
            });
        }
    };

    fn manifestKind(kind: []const u8) ManifestKind {
        if (std.mem.eql(u8, kind, "file")) return .file;
        if (std.mem.eql(u8, kind, "dir")) return .dir;
        if (std.mem.eql(u8, kind, "link")) return .link;
        return .other;
    }

    fn buildManifestSide(self: *CrossCopy, side: Side, manifest: *Manifest, src_dir: []const u8, rel_dir: []const u8) bool {
        var listing = self.listSide(side, src_dir) orelse return false;
        defer listing.deinit();
        if (listing.truncated) {
            self.fail("{s} on {s}: directory too large to enumerate", .{
                tailOf(src_dir), self.hostLabel(.src),
            });
            return false;
        }
        for (listing.entries) |e| {
            var rel_buf: [4096]u8 = undefined;
            const rel = std.fmt.bufPrint(&rel_buf, "{s}{s}{s}", .{
                rel_dir,
                if (rel_dir.len == 0) "" else "/",
                e.name,
            }) catch {
                self.fail("source path too long under {s}", .{tailOf(src_dir)});
                return false;
            };
            manifest.append(rel, e) catch {
                self.fail("source tree is too large to manifest", .{});
                return false;
            };
            if (manifestKind(e.kind) == .dir) {
                var child_buf: [4096]u8 = undefined;
                const child = treePath(&child_buf, src_dir, e.name) orelse {
                    self.fail("source path too long under {s}", .{tailOf(src_dir)});
                    return false;
                };
                if (!self.buildManifestSide(side, manifest, child, rel)) return false;
            }
        }
        return true;
    }

    fn buildManifest(self: *CrossCopy, manifest: *Manifest, src_dir: []const u8, rel_dir: []const u8) bool {
        return self.buildManifestSide(.src, manifest, src_dir, rel_dir);
    }

    fn treePath(buf: []u8, root: []const u8, rel: []const u8) ?[]const u8 {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ if (root.len == 1) "" else root, rel }) catch null;
    }

    fn copyLink(self: *CrossCopy, target: []const u8, dst_path: []const u8, no_replace: bool) bool {
        var temp_buf: [4096]u8 = undefined;
        const temp_id: u64 = if (self.job_id != 0) self.job_id else @intCast(c.getpid());
        const temp = std.fmt.bufPrint(&temp_buf, "{s}.skpart-link-{d}", .{ dst_path, temp_id }) catch {
            self.fail("destination path too long: {s}", .{tailOf(dst_path)});
            return false;
        };
        self.dst.deletePath(temp) catch {};
        if (!self.symlinkDst(target, temp)) return false;
        if (!self.renameDst(temp, dst_path, no_replace)) {
            self.dst.deletePath(temp) catch {};
            return false;
        }
        return true;
    }

    fn copyManifest(self: *CrossCopy, manifest: *const Manifest, src_root: []const u8, dst_root: []const u8, root: fsdrive.Entry, allow_resume: bool, claim_root: bool) bool {
        if (claim_root) {
            self.dst.mkdir(dst_root) catch |err| {
                self.fail("create destination {s}: {s}", .{ tailOf(dst_root), if (err == fsdrive.Error.FsOpFailed) self.dst.lastErr() else @errorName(err) });
                return false;
            };
        } else if (!self.mkdirDst(dst_root)) return false;
        for (manifest.items.items) |*item| {
            var sbuf: [4096]u8 = undefined;
            var dbuf: [4096]u8 = undefined;
            const sp = treePath(&sbuf, src_root, item.rel) orelse {
                self.fail("source path too long under {s}", .{tailOf(src_root)});
                return false;
            };
            const dp = treePath(&dbuf, dst_root, item.rel) orelse {
                self.fail("destination path too long under {s}", .{tailOf(dst_root)});
                return false;
            };
            var stat_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer stat_arena.deinit();
            const current = self.statRequired(.src, stat_arena.allocator(), sp) orelse return false;
            if (!item.matches(current)) {
                self.fail("source changed while copying: {s}", .{tailOf(sp)});
                return false;
            }
            switch (item.kind) {
                .dir => if (!self.mkdirDst(dp)) return false,
                .file => {
                    if (!self.copyFile(sp, dp, item.size, allow_resume, false)) return false;
                    _ = stat_arena.reset(.retain_capacity);
                    const after = self.statRequired(.src, stat_arena.allocator(), sp) orelse return false;
                    if (!item.matches(after)) {
                        self.fail("source changed while copying: {s}", .{tailOf(sp)});
                        return false;
                    }
                },
                .link => if (!self.copyLink(item.target, dp, false)) return false,
                .other => {
                    self.fail("unsupported source entry was not copied: {s}", .{tailOf(sp)});
                    return false;
                },
            }
        }
        var i = manifest.items.items.len;
        while (i > 0) {
            i -= 1;
            const item = &manifest.items.items[i];
            if (item.kind != .dir) continue;
            var dbuf: [4096]u8 = undefined;
            const dp = treePath(&dbuf, dst_root, item.rel) orelse continue;
            self.dst.chmod(dp, item.mode) catch {};
            self.dst.utimens(dp, item.atime_ms, item.mtime_ms) catch {};
        }
        self.dst.chmod(dst_root, root.mode) catch {};
        self.dst.utimens(dst_root, root.atime_ms, root.mtime_ms) catch {};
        return true;
    }

    fn rootMatches(expected: fsdrive.Entry, current: fsdrive.Entry) bool {
        if (manifestKind(expected.kind) != manifestKind(current.kind) or expected.mode != current.mode or
            expected.dev != current.dev or expected.ino != current.ino or
            expected.mtime_ns != current.mtime_ns or expected.ctime_ns != current.ctime_ns)
            return false;
        if (std.mem.eql(u8, expected.kind, "file") and expected.size != current.size) return false;
        if (std.mem.eql(u8, expected.kind, "link"))
            return std.mem.eql(u8, expected.target orelse "", current.target orelse "");
        return true;
    }

    fn validateManifest(self: *CrossCopy, expected: *const Manifest, src_root: []const u8, root: fsdrive.Entry) bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const current_root = self.statRequired(.src, arena.allocator(), src_root) orelse return false;
        if (!rootMatches(root, current_root)) {
            self.fail("source root changed while it was copied: {s}", .{tailOf(src_root)});
            return false;
        }
        var current = Manifest{ .allocator = self.allocator };
        defer current.deinit();
        if (!self.buildManifest(&current, src_root, "")) return false;
        current.sort();
        if (current.items.items.len != expected.items.items.len) {
            self.fail("source tree changed while it was copied: entry count differs", .{});
            return false;
        }
        for (expected.items.items, current.items.items) |*want, *got| {
            if (!std.mem.eql(u8, want.rel, got.rel) or want.kind != got.kind or want.size != got.size or
                want.mode != got.mode or want.mtime_ns != got.mtime_ns or want.ctime_ns != got.ctime_ns or
                want.dev != got.dev or want.ino != got.ino or !std.mem.eql(u8, want.target, got.target))
            {
                self.fail("source tree changed while it was copied near {s}", .{tailOf(want.rel)});
                return false;
            }
        }
        return true;
    }

    fn fingerprint(root: fsdrive.Entry, manifest: *const Manifest) [Sha256.digest_length * 2]u8 {
        var hasher = Sha256.init(.{});
        // Renaming the root itself updates ctime on Linux. Identity,
        // content/target, mode, and mtime remain stable across the
        // quarantine rename and still detect a captured replacement.
        stampEntry(&hasher, "", root.kind, root.size, root.mode, root.mtime_ns, 0, root.dev, root.ino, root.target orelse "");
        for (manifest.items.items) |*item| {
            if (item.rel.len == 0) continue;
            stampEntry(&hasher, item.rel, @tagName(item.kind), item.size, item.mode, item.mtime_ns, item.ctime_ns, item.dev, item.ino, item.target);
        }
        var digest: [Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);
        var hex: [Sha256.digest_length * 2]u8 = undefined;
        for (digest, 0..) |b, i|
            _ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
        return hex;
    }

    fn durableMatchesRoot(durable: CrossDurable, root: fsdrive.Entry) bool {
        return durable.source_kind.len > 0 and
            std.mem.eql(u8, durable.source_kind, root.kind) and
            durable.source_dev == root.dev and durable.source_ino == root.ino;
    }

    fn snapshotMatches(self: *CrossCopy, path: []const u8, durable: CrossDurable) bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const root = self.statProbe(.src, arena.allocator(), path) orelse return false;
        if (!durableMatchesRoot(durable, root)) return false;
        var manifest = Manifest{ .allocator = self.allocator };
        defer manifest.deinit();
        if (std.mem.eql(u8, root.kind, "dir")) {
            if (!self.buildManifest(&manifest, path, "")) return false;
            manifest.sort();
        } else manifest.append("", root) catch return false;
        const got = fingerprint(root, &manifest);
        return durable.fingerprint.len == got.len and std.mem.eql(u8, durable.fingerprint, &got);
    }

    fn verifyDestination(self: *CrossCopy, manifest: *const Manifest, src_root: []const u8, dst_root: []const u8, root: fsdrive.Entry) bool {
        if (std.mem.eql(u8, root.kind, "file")) {
            const sh = self.hashCached(.src, src_root) orelse return false;
            const dh = self.hashCached(.dst, dst_root) orelse return false;
            if (!std.mem.eql(u8, &sh, &dh)) {
                self.fail("destination no longer proves copied file {s}", .{tailOf(dst_root)});
                return false;
            }
            return true;
        }
        if (std.mem.eql(u8, root.kind, "link")) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const dest = self.statRequired(.dst, arena.allocator(), dst_root) orelse return false;
            if (!std.mem.eql(u8, dest.kind, "link") or
                !std.mem.eql(u8, dest.target orelse "", root.target orelse ""))
            {
                self.fail("destination no longer proves copied link {s}", .{tailOf(dst_root)});
                return false;
            }
            return true;
        }
        var root_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer root_arena.deinit();
        const dst_root_stat = self.statRequired(.dst, root_arena.allocator(), dst_root) orelse return false;
        if (!std.mem.eql(u8, dst_root_stat.kind, "dir")) {
            self.fail("destination no longer proves copied directory {s}", .{tailOf(dst_root)});
            return false;
        }
        for (manifest.items.items) |*item| {
            var sbuf: [4096]u8 = undefined;
            var dbuf: [4096]u8 = undefined;
            const sp = treePath(&sbuf, src_root, item.rel) orelse return false;
            const dp = treePath(&dbuf, dst_root, item.rel) orelse return false;
            switch (item.kind) {
                .file => {
                    const sh = self.hashCached(.src, sp) orelse return false;
                    const dh = self.hashCached(.dst, dp) orelse return false;
                    if (!std.mem.eql(u8, &sh, &dh)) {
                        self.fail("destination no longer proves copied file {s}", .{tailOf(dp)});
                        return false;
                    }
                },
                .link => {
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const dest = self.statRequired(.dst, arena.allocator(), dp) orelse return false;
                    if (!std.mem.eql(u8, dest.kind, "link") or
                        !std.mem.eql(u8, dest.target orelse "", item.target))
                    {
                        self.fail("destination no longer proves copied link {s}", .{tailOf(dp)});
                        return false;
                    }
                },
                .dir => {
                    var arena = std.heap.ArenaAllocator.init(self.allocator);
                    defer arena.deinit();
                    const dest = self.statRequired(.dst, arena.allocator(), dp) orelse return false;
                    if (!std.mem.eql(u8, dest.kind, "dir")) {
                        self.fail("destination no longer proves copied directory {s}", .{tailOf(dp)});
                        return false;
                    }
                },
                .other => return false,
            }
        }
        return true;
    }

    fn destinationShapeMatches(self: *CrossCopy, expected: *const Manifest, dst_root: []const u8) bool {
        var actual = Manifest{ .allocator = self.allocator };
        defer actual.deinit();
        if (!self.buildManifestSide(.dst, &actual, dst_root, "")) return false;
        actual.sort();
        if (actual.items.items.len != expected.items.items.len) return false;
        for (expected.items.items, actual.items.items) |*want, *got| {
            if (!std.mem.eql(u8, want.rel, got.rel) or want.kind != got.kind) return false;
            if (want.kind == .file and want.size != got.size) return false;
            if (want.kind == .link and !std.mem.eql(u8, want.target, got.target)) return false;
        }
        return true;
    }

    fn quarantineSource(self: *CrossCopy, src_path: []const u8, durable: CrossDurable) bool {
        while (true) {
            self.src.renameNoReplace(src_path, durable.quarantine) catch |err| {
                if (isTransportError(err)) {
                    if (!self.reconnect(.src)) return false;
                } else if (err == fsdrive.Error.BadRequest) {
                    self.fail("source host cannot atomically quarantine a move source", .{});
                    return false;
                } else {
                    const detail = self.src.lastErr();
                    if (std.mem.indexOf(u8, detail, "EXIST") == null and
                        std.mem.indexOf(u8, detail, "NOENT") == null)
                    {
                        self.failOp(.src, "quarantine", src_path, err);
                        return false;
                    }
                }
                // Rename may have committed before its reply was lost.
                // Only the persisted source snapshot can claim the
                // quarantine; an unrelated collision is never removed.
                if (self.snapshotMatches(durable.quarantine, durable)) {
                    self.hashRefreshAfterRename(.src, durable.quarantine);
                    return true;
                }
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                if (self.statProbe(.src, arena.allocator(), durable.quarantine) != null) {
                    self.fail("source quarantine collision; retained both paths", .{});
                    return false;
                }
                _ = arena.reset(.retain_capacity);
                if (self.statProbe(.src, arena.allocator(), src_path) == null) {
                    self.fail("source disappeared before it could be quarantined", .{});
                    return false;
                }
                continue;
            };
            self.hashRefreshAfterRename(.src, durable.quarantine);
            return true;
        }
    }

    fn restoreQuarantine(self: *CrossCopy, src_path: []const u8, quarantine: []const u8) bool {
        while (true) {
            self.src.renameNoReplace(quarantine, src_path) catch |err| {
                if (isTransportError(err)) {
                    if (!self.reconnect(.src)) return false;
                    continue;
                }
                self.fail("could not restore source; retained it at {s}", .{quarantine});
                return false;
            };
            return true;
        }
    }

    fn deleteOwnedDestinationPath(self: *CrossCopy, path: []const u8) bool {
        while (true) {
            self.dst.deletePath(path) catch |err| {
                if (err == fsdrive.Error.FsOpFailed and isNoEnt(self.dst)) return true;
                if (isTransportError(err)) {
                    if (!self.reconnect(.dst)) return false;
                    continue;
                }
                self.failOp(.dst, "remove canceled staging path", path, err);
                return false;
            };
            return true;
        }
    }

    /// Remove the journaled no-replace stage without following symlinks.
    fn removeDestinationStage(self: *CrossCopy, stage: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const before = self.fail_len;
        if (self.statProbe(.dst, arena.allocator(), stage)) |root| {
            if (std.mem.eql(u8, root.kind, "dir")) {
                var manifest = Manifest{ .allocator = self.allocator };
                defer manifest.deinit();
                if (!self.buildManifestSide(.dst, &manifest, stage, "")) return false;
                var i = manifest.items.items.len;
                while (i > 0) {
                    i -= 1;
                    var child_buf: [4096]u8 = undefined;
                    const child = treePath(&child_buf, stage, manifest.items.items[i].rel) orelse {
                        self.fail("destination staging path is too long: {s}", .{tailOf(stage)});
                        return false;
                    };
                    if (!self.deleteOwnedDestinationPath(child)) return false;
                }
            }
            if (!self.deleteOwnedDestinationPath(stage)) return false;
        } else if (isNoEnt(self.dst)) {
            self.fail_len = before;
        } else return false;

        // A root file is copied through this sibling before it is
        // renamed to `stage`; cancellation can arrive between those two.
        var part_buf: [4096]u8 = undefined;
        const part = std.fmt.bufPrint(&part_buf, "{s}.skpart", .{stage}) catch {
            self.fail("destination staging path is too long: {s}", .{tailOf(stage)});
            return false;
        };
        if (!self.deleteOwnedDestinationPath(part)) return false;
        const link_part = std.fmt.bufPrint(&part_buf, "{s}.skpart-link-{d}", .{ stage, self.job_id }) catch return false;
        if (!self.deleteOwnedDestinationPath(link_part)) return false;
        const legacy_link_part = std.fmt.bufPrint(&part_buf, "{s}.skpart-link", .{stage}) catch return false;
        return self.deleteOwnedDestinationPath(legacy_link_part);
    }

    fn removeCanceledPartials(self: *CrossCopy, src_root: []const u8, dst_root: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const root = self.statRequired(.src, arena.allocator(), src_root) orelse return false;
        var manifest = Manifest{ .allocator = self.allocator };
        defer manifest.deinit();
        if (std.mem.eql(u8, root.kind, "dir")) {
            if (!self.buildManifest(&manifest, src_root, "")) return false;
        } else {
            manifest.append("", root) catch {
                self.fail("cannot enumerate canceled transfer staging", .{});
                return false;
            };
        }
        for (manifest.items.items) |*item| {
            var dst_buf: [4096]u8 = undefined;
            const destination = if (item.rel.len == 0)
                dst_root
            else
                treePath(&dst_buf, dst_root, item.rel) orelse {
                    self.fail("destination staging path is too long: {s}", .{tailOf(dst_root)});
                    return false;
                };
            var part_buf: [4096]u8 = undefined;
            const part = switch (item.kind) {
                .file => std.fmt.bufPrint(&part_buf, "{s}.skpart", .{destination}),
                .link => std.fmt.bufPrint(&part_buf, "{s}.skpart-link-{d}", .{ destination, self.job_id }),
                else => continue,
            } catch {
                self.fail("destination staging path is too long: {s}", .{tailOf(destination)});
                return false;
            };
            if (!self.deleteOwnedDestinationPath(part)) return false;
            if (item.kind == .link) {
                const legacy = std.fmt.bufPrint(&part_buf, "{s}.skpart-link", .{destination}) catch return false;
                if (!self.deleteOwnedDestinationPath(legacy)) return false;
            }
        }
        return true;
    }

    const InstallRename = enum { installed, transport, canceled, failed };

    /// The exclusive final rename, serialized against cancellation when
    /// the job is journaled.
    fn installRename(self: *CrossCopy, spec: Spec, stage: []const u8, dst_root: []const u8) InstallRename {
        if (spec.job_id != 0 and spec.journal_dir.len > 0) {
            const guard = fsjournal.lockControl(spec.journal_dir, spec.job_id) catch {
                self.fail("cannot lock staged destination install: {s}", .{tailOf(dst_root)});
                return .failed;
            };
            defer guard.release();
            if (fsjournal.cancelRequested(spec.journal_dir, spec.job_id)) {
                durable_state.cancel_requested = true;
                return .canceled;
            }
            return self.installRenameOnce(stage, dst_root);
        }
        return self.installRenameOnce(stage, dst_root);
    }

    fn installRenameOnce(self: *CrossCopy, stage: []const u8, dst_root: []const u8) InstallRename {
        self.dst.renameNoReplace(stage, dst_root) catch |err| {
            if (isTransportError(err)) return .transport;
            self.failOp(.dst, "install", dst_root, err);
            return .failed;
        };
        self.hashRefreshAfterRename(.dst, dst_root);
        return .installed;
    }

    fn installStagedRoot(self: *CrossCopy, spec: Spec, manifest: *const Manifest, src_root: []const u8, stage: []const u8, dst_root: []const u8, root: fsdrive.Entry) bool {
        while (true) {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const staged = self.statProbe(.dst, arena.allocator(), stage);
            const final = self.statProbe(.dst, arena.allocator(), dst_root);
            if (staged) |staged_root| {
                if (!std.mem.eql(u8, staged_root.kind, root.kind) or
                    (std.mem.eql(u8, root.kind, "dir") and !self.destinationShapeMatches(manifest, stage)) or
                    !self.verifyDestination(manifest, src_root, stage, root))
                {
                    self.fail("staged destination changed before install: {s}", .{tailOf(stage)});
                    return false;
                }
                if (final != null) {
                    self.fail("destination appeared before staged directory install: {s}", .{tailOf(dst_root)});
                    return false;
                }
                switch (self.installRename(spec, stage, dst_root)) {
                    .installed => return true,
                    .transport => {
                        // Reconnect outside the control lock: backoff can
                        // take a minute and cancellation must stay
                        // persistable meanwhile.
                        if (!self.reconnect(.dst)) return false;
                        continue;
                    },
                    .canceled, .failed => return false,
                }
            }
            if (final != null and
                (!std.mem.eql(u8, root.kind, "dir") or self.destinationShapeMatches(manifest, dst_root)) and
                self.verifyDestination(manifest, src_root, dst_root, root)) return true;
            self.fail("staged destination vanished before install: {s}", .{tailOf(stage)});
            return false;
        }
    }

    fn isNoEnt(fs: *const fsdrive.Fs) bool {
        return noEntDetail(fs.lastErr());
    }

    fn noEntDetail(detail: []const u8) bool {
        return std.mem.indexOf(u8, detail, "NOENT") != null;
    }

    /// A transport can die after the source daemon applied deletion but
    /// before its reply arrived. Retrying then returns NOENT, which is
    /// the successful idempotent outcome rather than data loss.
    fn deleteSourcePath(self: *CrossCopy, path: []const u8, kind: ManifestKind, dev: u64, ino: u64) bool {
        while (true) {
            self.src.deletePath(path) catch |err| {
                if (err == fsdrive.Error.FsOpFailed and isNoEnt(self.src)) return true;
                if (!isTransportError(err)) {
                    self.failOp(.src, "delete", path, err);
                    return false;
                }
                if (!self.reconnect(.src)) return false;
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const current = self.statProbe(.src, arena.allocator(), path) orelse {
                    if (isNoEnt(self.src)) return true;
                    self.fail("cannot resolve ambiguous source deletion: {s}", .{tailOf(path)});
                    return false;
                };
                if (manifestKind(current.kind) != kind or current.dev != dev or current.ino != ino) {
                    self.fail("source deletion encountered replacement content; retained it: {s}", .{tailOf(path)});
                    return false;
                }
                continue;
            };
            return true;
        }
    }

    fn deleteCopiedFile(self: *CrossCopy, item: *const ManifestItem, src_path: []const u8, dst_path: []const u8) bool {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const current = self.statProbe(.src, arena.allocator(), src_path) orelse {
            if (isNoEnt(self.src)) return true;
            self.fail("cannot prove source before deletion: {s}", .{tailOf(src_path)});
            return false;
        };
        if (!item.matches(current)) {
            self.fail("source changed after it was copied; left in place: {s}", .{tailOf(src_path)});
            return false;
        }
        if (item.kind == .file) {
            const sh = self.hashCached(.src, src_path) orelse return false;
            const dh = self.hashCached(.dst, dst_path) orelse return false;
            if (!std.mem.eql(u8, &sh, &dh)) {
                self.fail("source changed after it was copied; left in place: {s}", .{tailOf(src_path)});
                return false;
            }
        } else if (item.kind == .link) {
            var dst_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer dst_arena.deinit();
            const dest = self.statRequired(.dst, dst_arena.allocator(), dst_path) orelse return false;
            if (!std.mem.eql(u8, dest.kind, "link") or
                !std.mem.eql(u8, dest.target orelse "", item.target))
            {
                self.fail("destination does not prove copied link {s}", .{tailOf(dst_path)});
                return false;
            }
        }
        _ = arena.reset(.retain_capacity);
        const final_source = self.statProbe(.src, arena.allocator(), src_path) orelse {
            if (isNoEnt(self.src)) return true;
            self.fail("cannot re-check source before deletion: {s}", .{tailOf(src_path)});
            return false;
        };
        if (!item.matches(final_source)) {
            self.fail("source changed after it was copied; left in place: {s}", .{tailOf(src_path)});
            return false;
        }
        return self.deleteSourcePath(src_path, item.kind, item.dev, item.ino);
    }

    fn deleteManifest(self: *CrossCopy, manifest: *const Manifest, src_root: []const u8, dst_root: []const u8, root: fsdrive.Entry) bool {
        var i = manifest.items.items.len;
        while (i > 0) {
            i -= 1;
            const item = &manifest.items.items[i];
            var sbuf: [4096]u8 = undefined;
            var dbuf: [4096]u8 = undefined;
            const sp = treePath(&sbuf, src_root, item.rel) orelse return false;
            const dp = treePath(&dbuf, dst_root, item.rel) orelse return false;
            if (item.kind == .dir) {
                // rmdir refuses unexpected content created after the
                // manifest validation, preserving it and failing the job.
                if (!self.deleteSourcePath(sp, item.kind, item.dev, item.ino)) return false;
            } else if (!self.deleteCopiedFile(item, sp, dp)) return false;
        }
        return self.deleteSourcePath(src_root, manifestKind(root.kind), root.dev, root.ino);
    }
};

/// Last path component plus enough parent to identify it, for error
/// text that has to fit on one line.
fn tailOf(path: []const u8) []const u8 {
    if (path.len <= 72) return path;
    return path[path.len - 72 ..];
}

/// Interruptible sleep: SIGSTOP/SIGCONT (the daemon's pause control)
/// lands as EINTR here, and the remaining time is what the loop waits.
fn sleepMs(ms: u32) void {
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

/// Test hook that widens the durable deletion boundary for crash injection.
fn delayDeletingForTest() void {
    delayForTest("SKETERM_FSJOB_DELETE_DELAY_MS");
}

fn delayForTest(name: [*:0]const u8) void {
    const raw = c.getenv(name) orelse return;
    const text = std.mem.span(@as([*:0]const u8, @ptrCast(raw)));
    const ms = std.fmt.parseInt(u32, text, 10) catch return;
    sleepMs(@min(ms, 10_000));
}

fn cancelRequested(spec: Spec) bool {
    return durableCancelRequested(spec.journal_dir, spec.job_id);
}

/// Open one side, retrying the dial itself: the destination daemon may
/// still be starting, or the route may be flapping at exactly the wrong
/// moment. `max_tries` caps the attempts (0 = the full reconnect
/// budget; direct remote-to-remote submissions set a small cap so an
/// unreachable peer fails in seconds). No sleep follows the final
/// failed attempt — the caller reports it immediately.
fn connectHostFsRetrying(allocator: std.mem.Allocator, host: []const u8, side: Side, max_tries: u32, spec: Spec, allow_canceled: bool) ?fsdrive.Fs {
    const tries = if (max_tries == 0) RECONNECT_ATTEMPTS else @min(max_tries, RECONNECT_ATTEMPTS);
    var attempt: u32 = 0;
    while (attempt < tries) : (attempt += 1) {
        if (!allow_canceled and cancelRequested(spec)) return null;
        if (connectHostFs(allocator, host)) |fs| return fs else |_| {}
        if (attempt + 1 >= tries) break;
        const wait_ms = RECONNECT_BACKOFF_MS[@min(attempt, RECONNECT_BACKOFF_MS.len - 1)];
        var buf: [160]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("{s} host {s} unreachable -- retrying in {d}s", .{
            side.label(), if (host.len == 0) "local" else host, wait_ms / 1000,
        }) catch {};
        emit(.{ .ev = "progress", .message = w.buffered() });
        sleepMs(wait_ms);
    }
    return null;
}

fn makeSourceQuarantine(src: []const u8, job_id: u64, out: []u8) ?[]const u8 {
    const parent = std.fs.path.dirname(src) orelse return null;
    var random: [16]u8 = undefined;
    if (c.getentropy(&random, random.len) != 0) return null;
    var nonce: [32]u8 = undefined;
    for (random, 0..) |b, i|
        _ = std.fmt.bufPrint(nonce[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    return std.fmt.bufPrint(out, "{s}/.sketerm-move-{d}-{s}", .{
        if (parent.len == 1) "" else parent,
        job_id,
        nonce,
    }) catch null;
}

fn makeDestinationStage(dst: []const u8, job_id: u64, out: []u8) ?[]const u8 {
    const parent = std.fs.path.dirname(dst) orelse return null;
    var random: [16]u8 = undefined;
    if (c.getentropy(&random, random.len) != 0) return null;
    var nonce: [32]u8 = undefined;
    for (random, 0..) |b, i|
        _ = std.fmt.bufPrint(nonce[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    return std.fmt.bufPrint(out, "{s}/.sketerm-copy-{d}-{s}", .{
        if (parent.len == 1) "" else parent,
        job_id,
        nonce,
    }) catch null;
}

fn durableFromSpec(spec: Spec) CrossDurable {
    return .{
        .quarantine = spec.source_quarantine,
        .destination_stage = spec.destination_stage,
        .fingerprint = spec.source_fingerprint,
        .source_kind = spec.source_kind,
        .source_dev = spec.source_dev,
        .source_ino = spec.source_ino,
    };
}

fn cancellationSpec(spec: Spec, phase: []const u8, durable: CrossDurable, progress: *const Progress) Spec {
    var out = spec;
    out.phase = phase;
    out.source_quarantine = durable.quarantine;
    out.destination_stage = durable.destination_stage;
    out.source_fingerprint = durable.fingerprint;
    out.source_kind = durable.source_kind;
    out.source_dev = durable.source_dev;
    out.source_ino = durable.source_ino;
    out.done = progress.done;
    out.total = progress.total;
    out.resumed_from = progress.resumed;
    out.files_done = progress.entries_done;
    out.files_total = progress.entries_total;
    return out;
}

const DeleteCommit = enum { committed, canceled, failed };

fn commitDeleting(spec: Spec, progress: *const Progress, durable: CrossDurable) DeleteCommit {
    if (spec.job_id == 0 or spec.journal_dir.len == 0)
        return if (persistCrossPhase(spec, "deleting", progress, durable)) .committed else .failed;
    const guard = fsjournal.lockControl(spec.journal_dir, spec.job_id) catch return .failed;
    if (fsjournal.cancelRequested(spec.journal_dir, spec.job_id)) {
        guard.release();
        durable_state.cancel_requested = true;
        return .canceled;
    }
    const saved = saveCrossPhase(spec, "deleting", progress, durable);
    guard.release();
    if (!saved) return .failed;
    emitCrossPhase("deleting", progress);
    return .committed;
}

/// Cancellation cleanup hit transport trouble: keep the durable record
/// recoverable instead of answering permanently.
fn cancelCleanupRetry(msg: []const u8) u8 {
    durable_state.retryable_cleanup = true;
    return emitErrorKind("retryable_cleanup", msg);
}

/// The verdict every probe in the cancellation resolver shares:
/// transport trouble stays recoverable, anything else is permanent.
fn cancelOutcome(cc: *const CrossCopy, retry_msg: []const u8, permanent_msg: []const u8) u8 {
    if (cc.retryable_transport) return cancelCleanupRetry(retry_msg);
    return emitErrorKind("permanent", permanent_msg);
}

fn connectCancellationHost(allocator: std.mem.Allocator, host: []const u8) ?fsdrive.Fs {
    var attempt: usize = 0;
    while (attempt < 3) : (attempt += 1) {
        if (connectHostFs(allocator, host)) |fs| return fs else |_| {}
        if (attempt + 1 < 3) sleepMs(CLEANUP_RECONNECT_BACKOFF_MS[attempt]);
    }
    return null;
}

fn emitCanceledAfterStageCleanup(allocator: std.mem.Allocator, spec: Spec, source: *fsdrive.Fs, message: []const u8) u8 {
    if (fsjournal.phaseRank(spec.phase) >= fsjournal.phaseRank("copied"))
        return emitCanceled(message);
    var dst = connectCancellationHost(allocator, spec.dst_host) orelse {
        return cancelCleanupRetry("cancel requested; reconnecting later to remove destination staging data");
    };
    defer dst.deinit();
    var cleanup = CrossCopy{
        .allocator = allocator,
        .src = source,
        .dst = &dst,
        .journal_dir = spec.journal_dir,
        .job_id = spec.job_id,
        .src_host = spec.src_host,
        .dst_host = spec.dst_host,
        .move = true,
    };
    defer cleanup.deinitCaches();
    const cleaned = if (spec.destination_stage.len > 0)
        cleanup.removeDestinationStage(spec.destination_stage)
    else
        cleanup.removeCanceledPartials(spec.src, spec.dst);
    if (!cleaned) {
        if (cleanup.retryable_transport)
            return cancelCleanupRetry("cancel requested; reconnecting later to remove destination staging data");
        var buf: [400]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("cancel requested; destination staging data retained at {s}: {s}", .{
            spec.destination_stage,
            cleanup.failedReason(),
        }) catch return emitErrorKind("permanent", "cancel requested; destination staging data could not be removed");
        return emitErrorKind("permanent", w.buffered());
    }
    return emitCanceled(message);
}

/// Resolve a durable move cancellation without ever resuming source deletion.
fn finishMoveCancellation(allocator: std.mem.Allocator, spec: Spec) u8 {
    durable_state.cancel_requested = true;
    const phase = fsjournal.phaseRank(spec.phase);
    if (!spec.delete_src) {
        if (spec.destination_stage.len == 0)
            return emitCanceled("transfer canceled; source left in place");
        var dst = connectCancellationHost(allocator, spec.dst_host) orelse {
            return cancelCleanupRetry("cancel requested; reconnecting later to remove destination staging data");
        };
        defer dst.deinit();
        var cleanup = CrossCopy{
            .allocator = allocator,
            .src = &dst,
            .dst = &dst,
            .journal_dir = spec.journal_dir,
            .job_id = spec.job_id,
            .src_host = spec.dst_host,
            .dst_host = spec.dst_host,
        };
        defer cleanup.deinitCaches();
        if (cleanup.removeDestinationStage(spec.destination_stage))
            return emitCanceled("transfer canceled; destination staging data removed");
        return cancelOutcome(
            &cleanup,
            "cancel requested; reconnecting later to remove destination staging data",
            "cancel requested; destination staging data could not be removed",
        );
    }
    if (phase >= fsjournal.phaseRank("source_deleted")) {
        durable_state.progress.phase.set("source_deleted");
        emitCopyDone(&.{
            .done = spec.done,
            .total = spec.total,
            .resumed = spec.resumed_from,
            .entries_done = spec.files_done,
            .entries_total = spec.files_total,
        });
        return 0;
    }

    var src = connectCancellationHost(allocator, spec.src_host) orelse {
        return cancelCleanupRetry("cancel requested; cannot reconnect to restore the source");
    };
    defer src.deinit();
    var cc = CrossCopy{
        .allocator = allocator,
        .src = &src,
        .dst = &src,
        .journal_dir = spec.journal_dir,
        .job_id = spec.job_id,
        .src_host = spec.src_host,
        .dst_host = spec.src_host,
        .move = true,
    };
    defer cc.deinitCaches();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const durable = durableFromSpec(spec);
    if (phase < fsjournal.phaseRank("copied") or spec.source_quarantine.len == 0) {
        if (cc.statProbe(.src, arena.allocator(), spec.src)) |root| {
            if (phase >= fsjournal.phaseRank("rename_planned") and !CrossCopy.durableMatchesRoot(durable, root))
                return emitErrorKind("permanent", "source identity changed before cancellation completed");
            if (phase >= fsjournal.phaseRank("copied")) {
                if (durable.fingerprint.len == 0)
                    return emitErrorKind("permanent", "move recovery record cannot prove the copied source");
                if (!cc.snapshotMatches(spec.src, durable))
                    return cancelOutcome(
                        &cc,
                        "cancel requested; reconnecting later to prove the source",
                        "source no longer matches the copied snapshot; cancellation remains pending",
                    );
            }
            return emitCanceledAfterStageCleanup(allocator, spec, &src, "transfer canceled; source left in place");
        }
        if (phase == fsjournal.phaseRank("rename_planned") and
            std.mem.eql(u8, spec.src_host, spec.dst_host))
        {
            // The atomic rename and its phase write are separate syscalls.
            // If cancellation won the lock after the rename but before the
            // journal write, destination identity proves completion.
            cc.fail_len = 0;
            _ = arena.reset(.retain_capacity);
            if (cc.statProbe(.src, arena.allocator(), spec.dst)) |destination| {
                if (CrossCopy.durableMatchesRoot(durable, destination)) {
                    var progress = Progress{
                        .done = @max(spec.done, 1),
                        .total = @max(spec.total, 1),
                        .resumed = spec.resumed_from,
                        .entries_done = @max(spec.files_done, 1),
                        .entries_total = @max(spec.files_total, 1),
                    };
                    _ = saveCrossPhase(spec, "source_deleted", &progress, durable);
                    emitCopyDone(&progress);
                    return 0;
                }
            }
        }
        return cancelOutcome(
            &cc,
            "cancel requested; source could not be inspected",
            if (CrossCopy.isNoEnt(cc.src))
                "source is missing before deletion committed; cancellation remains unresolved"
            else
                "source could not be inspected; cancellation remains unresolved",
        );
    }
    if (cc.statProbe(.src, arena.allocator(), spec.source_quarantine)) |_| {
        if (!cc.snapshotMatches(spec.source_quarantine, durable))
            return cancelOutcome(
                &cc,
                "cancel requested; reconnecting later to prove the source quarantine",
                "source quarantine no longer matches the copied source; retained it for recovery",
            );
        if (cc.restoreQuarantine(spec.src, spec.source_quarantine))
            return emitCanceledAfterStageCleanup(allocator, spec, &src, "move canceled; source restored and completed destination retained");
        if (cc.retryable_transport)
            return cancelCleanupRetry("cancel requested; reconnecting later to restore the source");
        // rename-no-replace may have committed before an error reply.
        cc.fail_len = 0;
        _ = arena.reset(.retain_capacity);
        if (cc.snapshotMatches(spec.src, durable)) {
            _ = arena.reset(.retain_capacity);
            if (cc.statProbe(.src, arena.allocator(), spec.source_quarantine) == null and CrossCopy.isNoEnt(cc.src))
                return emitCanceledAfterStageCleanup(allocator, spec, &src, "move canceled; source restored and completed destination retained");
        }
        return cancelOutcome(
            &cc,
            "cancel requested; reconnecting later to confirm source restoration",
            cc.failedReason(),
        );
    }
    if (!CrossCopy.isNoEnt(cc.src))
        return cancelOutcome(
            &cc,
            "cancel requested; source quarantine could not be inspected",
            "source quarantine could not be inspected; cancellation remains pending",
        );
    cc.fail_len = 0;
    _ = arena.reset(.retain_capacity);
    if (cc.statProbe(.src, arena.allocator(), spec.src)) |_| {
        if (cc.snapshotMatches(spec.src, durable))
            return emitCanceledAfterStageCleanup(allocator, spec, &src, "move canceled; source left in place and completed destination retained");
        return cancelOutcome(
            &cc,
            "cancel requested; reconnecting later to prove the source",
            "source path contains replacement content; quarantine retained for recovery",
        );
    }
    if (!CrossCopy.isNoEnt(cc.src))
        return cancelOutcome(
            &cc,
            "cancel requested; source location could not be inspected",
            "source location could not be inspected; cancellation remains pending",
        );
    return emitErrorKind("permanent", "source and quarantine are both missing before deletion committed; cancellation remains unresolved");
}

fn emitCrossDialFailure(spec: Spec, side: Side, host: []const u8) u8 {
    var buf: [160]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("cannot reach {s} host {s}", .{ side.label(), host }) catch
        return emitErrorKind("unreachable", "cannot connect host");
    if (spec.delete_src and
        fsjournal.phaseRank(spec.phase) >= fsjournal.phaseRank("rename_planned") and
        fsjournal.phaseRank(spec.phase) < fsjournal.phaseRank("source_deleted"))
    {
        return cancelCleanupRetry(w.buffered());
    }
    return emitErrorKind("unreachable", w.buffered());
}

fn runCrossCopy(allocator: std.mem.Allocator, spec_in: Spec) u8 {
    var spec = spec_in;
    // Older same-host attempts wrote `deleting` before rename reported
    // whether it had to fall back to copy. No quarantine means no copy
    // deletion ever started, so recover from the last honest boundary.
    if (spec.delete_src and std.mem.eql(u8, spec.src_host, spec.dst_host) and
        std.mem.eql(u8, spec.phase, "deleting") and spec.source_quarantine.len == 0)
        spec.phase = "rename_planned";
    if (spec.dst.len == 0) return emitError("cross_copy needs destination");
    if (spec.delete_src and spec.@"resume" and std.mem.eql(u8, spec.phase, "source_deleted")) {
        emit(.{
            .ev = "done",
            .done = spec.done,
            .total = spec.total,
            .resumed_from = spec.resumed_from,
            .files_done = spec.files_done,
            .files_total = spec.files_total,
            .phase = "source_deleted",
        });
        return 0;
    }
    durable_state.delete_started = moveDeletionStarted(spec.delete_src, spec.phase);
    const reconcile_staged_install = !spec.delete_src and spec.no_replace and
        fsjournal.phaseRank(spec.phase) >= fsjournal.phaseRank("destination_staged");
    if (cancelRequested(spec) and !reconcile_staged_install) return finishMoveCancellation(allocator, spec);
    const src_label = if (spec.src_host.len == 0) "local" else spec.src_host;
    const dst_label = if (spec.dst_host.len == 0) "local" else spec.dst_host;
    var src = connectHostFsRetrying(allocator, spec.src_host, .src, spec.dial_tries, spec, reconcile_staged_install) orelse
        return if (reconcile_staged_install)
            cancelCleanupRetry("cancel requested; reconnecting later to reconcile the destination install")
        else if (durable_state.cancel_requested)
            finishMoveCancellation(allocator, spec)
        else
            emitCrossDialFailure(spec, .src, src_label);
    defer src.deinit();
    var dst = connectHostFsRetrying(allocator, spec.dst_host, .dst, spec.dial_tries, spec, reconcile_staged_install) orelse
        return if (durable_state.cancel_requested) finishMoveCancellation(allocator, spec) else emitCrossDialFailure(spec, .dst, dst_label);
    defer dst.deinit();
    const journal_phase = fsjournal.phaseRank(spec.phase);
    const resume_phase = if (std.mem.eql(u8, spec.phase, "rename_planned")) 0 else journal_phase;
    var cc = CrossCopy{
        .allocator = allocator,
        .src = &src,
        .dst = &dst,
        .journal_dir = spec.journal_dir,
        .job_id = spec.job_id,
        .src_host = spec.src_host,
        .dst_host = spec.dst_host,
        .no_replace = spec.no_replace,
        .move = spec.delete_src,
        .progress = .{
            // Seed the journaled counters ONLY when the byte copy is
            // being skipped (resume_phase > 0: cleanup-phase recovery).
            // A rename_planned restart re-runs the copy and re-counts
            // its own bytes — seeding on top of that once SUMMED a
            // dead attempt's progress with the fresh run's (done grew
            // to 1.66x the file's size).
            .done = if (resume_phase > 0) spec.done else 0,
            .total = if (resume_phase > 0) spec.total else 0,
            .resumed = if (resume_phase > 0) spec.resumed_from else 0,
            .entries_done = if (resume_phase > 0) spec.files_done else 0,
            .entries_total = if (resume_phase > 0) spec.files_total else 0,
        },
    };
    defer cc.deinitCaches();
    var move_kind_buf: [16]u8 = undefined;
    var move_durable = durableFromSpec(spec);
    if (spec.delete_src and journal_phase == 0) {
        var move_arena = std.heap.ArenaAllocator.init(allocator);
        defer move_arena.deinit();
        const move_root = cc.statRequired(.src, move_arena.allocator(), spec.src) orelse return cc.emitFailure();
        const kind_len = @min(move_root.kind.len, move_kind_buf.len);
        @memcpy(move_kind_buf[0..kind_len], move_root.kind[0..kind_len]);
        move_durable.source_kind = move_kind_buf[0..kind_len];
        move_durable.source_dev = move_root.dev;
        move_durable.source_ino = move_root.ino;
        if (!persistCrossPhase(spec, "rename_planned", &cc.progress, move_durable))
            return emitError("move could not persist its source identity");
    } else if (spec.delete_src and std.mem.eql(u8, spec.phase, "rename_planned") and
        (move_durable.source_kind.len == 0 or move_durable.source_ino == 0))
    {
        return emitError("move recovery record has no source identity");
    }
    if (spec.delete_src and std.mem.eql(u8, spec.src_host, spec.dst_host) and
        (journal_phase == 0 or std.mem.eql(u8, spec.phase, "rename_planned")))
    {
        var control: ?fsjournal.ControlLock = null;
        if (spec.job_id != 0 and spec.journal_dir.len != 0) {
            control = fsjournal.lockControl(spec.journal_dir, spec.job_id) catch
                return emitError("move could not lock its atomic rename boundary");
            if (fsjournal.cancelRequested(spec.journal_dir, spec.job_id)) {
                control.?.release();
                durable_state.cancel_requested = true;
                return finishMoveCancellation(allocator, cancellationSpec(spec, "rename_planned", move_durable, &cc.progress));
            }
        }
        const rename_result = cc.tryRenameMove(spec.src, spec.dst, move_durable);
        if (rename_result == .moved) {
            durable_state.delete_started = true;
            cc.progress.done = 1;
            cc.progress.total = 1;
            cc.progress.entries_done = 1;
            cc.progress.entries_total = 1;
            const saved = saveCrossPhase(spec, "source_deleted", &cc.progress, move_durable);
            if (control) |guard| guard.release();
            if (saved) emitCrossPhase("source_deleted", &cc.progress);
        } else if (control) |guard| guard.release();
        switch (rename_result) {
            .moved => {
                emitCopyDone(&cc.progress);
                return 0;
            },
            .copy_fallback => {
                durable_state.delete_started = false;
            },
            .failed => return cc.emitFailure(),
        }
    }
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var durable = move_durable;
    var active_src = spec.src;
    var captured = false;
    if (spec.delete_src and resume_phase >= fsjournal.phaseRank("copied") and durable.quarantine.len > 0) {
        if (cc.statProbe(.src, arena.allocator(), durable.quarantine) != null) {
            active_src = durable.quarantine;
            captured = true;
            _ = arena.reset(.retain_capacity);
        } else if (resume_phase >= fsjournal.phaseRank("quarantined") and CrossCopy.isNoEnt(cc.src)) {
            // Cleanup completed before its final phase write. The
            // original path is unrelated once quarantine was durable.
            if (!persistCrossPhase(spec, "source_deleted", &cc.progress, durable))
                return emitError("move completed but its durable phase could not be saved");
            emitCopyDone(&cc.progress);
            return 0;
        } else if (resume_phase >= fsjournal.phaseRank("quarantined")) {
            cc.fail("cannot confirm quarantined source cleanup: {s}", .{tailOf(durable.quarantine)});
            return cc.emitFailure();
        }
    }
    const root = cc.statProbe(.src, arena.allocator(), active_src) orelse {
        // Version-3 journals had no quarantine identity. Preserve their
        // established recovery rule, but new records never infer from
        // the destination while a quarantine path is known.
        if (spec.delete_src and spec.@"resume" and resume_phase >= fsjournal.phaseRank("copied") and
            durable.quarantine.len == 0 and CrossCopy.isNoEnt(cc.src) and
            cc.statProbe(.dst, arena.allocator(), spec.dst) != null)
        {
            if (!persistCrossPhase(spec, "source_deleted", &cc.progress, durable))
                return emitError("move completed but its durable phase could not be saved");
            emitCopyDone(&cc.progress);
            return 0;
        }
        const detail = cc.src.lastErr();
        cc.fail("stat {s} on {s}: {s}", .{ tailOf(active_src), cc.hostLabel(.src), if (detail.len > 0) detail else "source is unavailable" });
        return cc.emitFailure();
    };
    if (spec.delete_src and resume_phase == 0 and !CrossCopy.durableMatchesRoot(durable, root)) {
        cc.fail("move source was replaced before copy fallback; retained it: {s}", .{tailOf(active_src)});
        return cc.emitFailure();
    }
    var manifest = CrossCopy.Manifest{ .allocator = allocator };
    defer manifest.deinit();
    if (std.mem.eql(u8, root.kind, "file") or std.mem.eql(u8, root.kind, "link")) {
        manifest.append("", root) catch {
            cc.fail("cannot manifest source root", .{});
            return cc.emitFailure();
        };
    } else if (std.mem.eql(u8, root.kind, "dir")) {
        cc.notice("counting files in {s}", .{tailOf(active_src)});
        if (!cc.buildManifest(&manifest, active_src, "")) return cc.emitFailure();
        manifest.sort();
    } else {
        cc.fail("unsupported source entry: {s}", .{tailOf(active_src)});
        return cc.emitFailure();
    }

    var destination_stage_buf: [4096]u8 = undefined;
    var stage_fingerprint_buf: [Sha256.digest_length * 2]u8 = undefined;
    // EVERY no_replace transfer stages: the exclusive final-name claim
    // otherwise makes the job's own partial root read as a collision on
    // retry, so an interrupted no-replace copy could never resume.
    const staged_root = spec.no_replace and
        resume_phase < fsjournal.phaseRank("copied");
    var copy_dst = spec.dst;
    if (staged_root) {
        if (durable.destination_stage.len == 0) {
            durable.destination_stage = makeDestinationStage(spec.dst, spec.job_id, &destination_stage_buf) orelse
                return emitError("cannot create destination staging path");
            if (!persistCrossPhase(spec, "rename_planned", &cc.progress, durable))
                return emitError("transfer could not persist its destination staging path");
        }
        copy_dst = durable.destination_stage;
    }
    // A no-replace destination that already exists is a collision —
    // UNLESS this restarted job can show a journaled prior attempt AND
    // the destination proves to be exactly the source's content: then
    // its previous attempt (or a lost final acknowledgment) already
    // delivered it, and reporting failure over bytes that are
    // verifiably in place would send the client into a retry loop
    // against its own success. A FRESH job never claims a matching
    // destination (an identical file is not proof that THIS job put it
    // there — the collision smoke pins that down for moves).
    // Only destination_staged proves this job completed and verified
    // its private root immediately before the exclusive rename. The
    // earlier rename_planned phase merely reserves a stage pathname;
    // treating it as ownership lets a retry claim an unrelated
    // identical collision and, for a move, delete the source.
    const prior_attempt = fsjournal.phaseRank(spec.phase) >= fsjournal.phaseRank("destination_staged");
    var already_installed = false;
    if (spec.no_replace and resume_phase == 0) {
        var final_arena = std.heap.ArenaAllocator.init(allocator);
        defer final_arena.deinit();
        if (cc.statProbe(.dst, final_arena.allocator(), spec.dst)) |existing_dst| {
            const before = cc.fail_len;
            const claimed = spec.@"resume" and prior_attempt and
                std.mem.eql(u8, existing_dst.kind, root.kind) and
                (!std.mem.eql(u8, root.kind, "dir") or cc.destinationShapeMatches(&manifest, spec.dst)) and
                cc.verifyDestination(&manifest, active_src, spec.dst, root);
            cc.fail_len = before;
            if (!claimed) {
                cc.fail("destination exists: {s}", .{tailOf(spec.dst)});
                return cc.emitFailure();
            }
            already_installed = true;
            cc.progress.total = if (std.mem.eql(u8, root.kind, "file")) root.size else manifest.total;
            cc.progress.entries_total = if (std.mem.eql(u8, root.kind, "dir")) manifest.files else 1;
            cc.progress.done = cc.progress.total;
            cc.progress.resumed = cc.progress.total;
            cc.progress.entries_done = cc.progress.entries_total;
            cc.progress.emitNow();
        }
    }

    if (resume_phase == 0 and !already_installed) {
        cc.progress.total = if (std.mem.eql(u8, root.kind, "file")) root.size else manifest.total;
        cc.progress.entries_total = if (std.mem.eql(u8, root.kind, "dir")) manifest.files else 1;
        cc.progress.emitNow();
        const copied = if (std.mem.eql(u8, root.kind, "file"))
            cc.copyFile(active_src, copy_dst, root.size, spec.@"resume", spec.no_replace and !staged_root)
        else if (std.mem.eql(u8, root.kind, "link")) blk: {
            const target = root.target orelse {
                cc.fail("source symlink has no readable target: {s}", .{tailOf(active_src)});
                break :blk false;
            };
            if (!cc.copyLink(target, copy_dst, spec.no_replace and !staged_root)) break :blk false;
            break :blk cc.progress.entryDone();
        } else cc.copyManifest(&manifest, active_src, copy_dst, root, spec.@"resume", spec.no_replace and !staged_root);
        if (!copied) return cc.emitFailure();
        if (std.mem.eql(u8, root.kind, "dir")) {
            if (!cc.validateManifest(&manifest, active_src, root)) return cc.emitFailure();
        } else {
            var verify_arena = std.heap.ArenaAllocator.init(allocator);
            defer verify_arena.deinit();
            const current = cc.statRequired(.src, verify_arena.allocator(), active_src) orelse
                return cc.emitFailure();
            if (!CrossCopy.rootMatches(root, current)) {
                cc.fail("source changed while it was copied: {s}", .{tailOf(active_src)});
                return cc.emitFailure();
            }
        }
    }
    if (staged_root and !already_installed) {
        if (resume_phase < fsjournal.phaseRank("destination_staged")) {
            stage_fingerprint_buf = CrossCopy.fingerprint(root, &manifest);
            durable.fingerprint = &stage_fingerprint_buf;
            durable.source_kind = root.kind;
            durable.source_dev = root.dev;
            durable.source_ino = root.ino;
            if (!cc.verifyDestination(&manifest, active_src, durable.destination_stage, root)) return cc.emitFailure();
            if (!persistCrossPhase(spec, "destination_staged", &cc.progress, durable))
                return emitError("staged copy could not persist its install boundary");
        } else {
            stage_fingerprint_buf = CrossCopy.fingerprint(root, &manifest);
            if (!CrossCopy.durableMatchesRoot(durable, root) or
                !std.mem.eql(u8, durable.fingerprint, &stage_fingerprint_buf))
            {
                cc.fail("source changed after destination staging; retained it: {s}", .{tailOf(active_src)});
                return cc.emitFailure();
            }
        }
        delayForTest("SKETERM_FSJOB_PRE_INSTALL_DELAY_MS");
        if (!cc.installStagedRoot(spec, &manifest, active_src, durable.destination_stage, spec.dst, root))
            return if (durable_state.cancel_requested)
                finishMoveCancellation(allocator, cancellationSpec(spec, "destination_staged", durable, &cc.progress))
            else
                cc.emitFailure();
        delayForTest("SKETERM_FSJOB_POST_INSTALL_DELAY_MS");
    }
    if (!spec.delete_src) {
        emitCopyDone(&cc.progress);
        return 0;
    }
    if (cc.canceled()) return finishMoveCancellation(allocator, spec);

    var fingerprint_buf: [Sha256.digest_length * 2]u8 = undefined;
    if (resume_phase < fsjournal.phaseRank("quarantined")) {
        fingerprint_buf = CrossCopy.fingerprint(root, &manifest);
        if (durable.fingerprint.len > 0 and
            (!CrossCopy.durableMatchesRoot(durable, root) or
                !std.mem.eql(u8, durable.fingerprint, &fingerprint_buf)))
        {
            cc.fail("source changed after its copy completed; left in place: {s}", .{tailOf(active_src)});
            return cc.emitFailure();
        }
        durable.fingerprint = &fingerprint_buf;
        durable.source_kind = root.kind;
        durable.source_dev = root.dev;
        durable.source_ino = root.ino;
    } else if (!CrossCopy.durableMatchesRoot(durable, root)) {
        cc.fail("quarantined source identity changed; retained it at {s}", .{tailOf(active_src)});
        return cc.emitFailure();
    }

    var quarantine_buf: [4096]u8 = undefined;
    if (!captured) {
        if (durable.quarantine.len == 0) {
            durable.quarantine = makeSourceQuarantine(spec.src, spec.job_id, &quarantine_buf) orelse
                return emitError("cannot create source quarantine path");
        }
        if (!cc.verifyDestination(&manifest, active_src, spec.dst, root)) return cc.emitFailure();
        if (!persistCrossPhase(spec, "copied", &cc.progress, durable))
            return emitError("copy completed but its durable move phase could not be saved");
        if (!cc.quarantineSource(spec.src, durable)) return cc.emitFailure();
        if (!cc.snapshotMatches(durable.quarantine, durable)) {
            _ = cc.restoreQuarantine(spec.src, durable.quarantine);
            if (cc.fail_len == 0)
                cc.fail("source changed during quarantine; restored it", .{});
            return cc.emitFailure();
        }
        active_src = durable.quarantine;
        captured = true;
    }
    // Test hook: hold the captured quarantine observable (journal still
    // "copied") so a rig can land a durable cancel deterministically
    // instead of racing the verify-then-commit gap.
    delayForTest("SKETERM_FSJOB_QUARANTINE_DELAY_MS");
    if (cc.canceled())
        return finishMoveCancellation(allocator, cancellationSpec(spec, "copied", durable, &cc.progress));
    if (!cc.verifyDestination(&manifest, active_src, spec.dst, root)) return cc.emitFailure();
    if (resume_phase < fsjournal.phaseRank("quarantined")) {
        if (!persistCrossPhase(spec, "quarantined", &cc.progress, durable)) {
            if (captured) _ = cc.restoreQuarantine(spec.src, durable.quarantine);
            return emitError("source quarantined but its durable phase could not be saved");
        }
    }
    if (cc.canceled())
        return finishMoveCancellation(allocator, cancellationSpec(spec, "quarantined", durable, &cc.progress));
    if (resume_phase < fsjournal.phaseRank("deleting")) {
        switch (commitDeleting(spec, &cc.progress, durable)) {
            .committed => {},
            .canceled => return finishMoveCancellation(allocator, cancellationSpec(spec, "quarantined", durable, &cc.progress)),
            .failed => return emitError("source cleanup could not persist its cancellation boundary"),
        }
    }
    // Past this durable boundary a tree may be partially removed. A
    // later cancellation must finish cleanup, never restore a partial
    // quarantine under the original source name.
    durable_state.delete_started = true;
    delayDeletingForTest();
    if (std.mem.eql(u8, root.kind, "dir")) {
        if (!cc.deleteManifest(&manifest, active_src, spec.dst, root)) {
            return cc.emitFailure();
        }
    } else if (!cc.deleteCopiedFile(&manifest.items.items[0], active_src, spec.dst)) {
        return cc.emitFailure();
    }
    if (!persistCrossPhase(spec, "source_deleted", &cc.progress, durable))
        return emitError("source was deleted but the durable move phase could not be saved");
    emitCopyDone(&cc.progress);
    return 0;
}

// ── find / grep ─────────────────────────────────────────────────

/// Case-insensitive glob: `*` and `?` wildcards; a pattern without
/// wildcards matches as a SUBSTRING (what a search box means).
pub fn nameMatches(pattern: []const u8, name: []const u8) bool {
    if (std.mem.indexOfAny(u8, pattern, "*?") == null)
        return std.ascii.indexOfIgnoreCase(name, pattern) != null;
    return globMatch(pattern, name);
}

fn globMatch(pattern: []const u8, name: []const u8) bool {
    // Iterative *-backtracking matcher, ASCII case-folded.
    var p: usize = 0;
    var n: usize = 0;
    var star_p: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (p < pattern.len and (pattern[p] == '?' or
            std.ascii.toLower(pattern[p]) == std.ascii.toLower(name[n])))
        {
            p += 1;
            n += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star_p = p;
            star_n = n;
            p += 1;
        } else if (star_p) |sp| {
            p = sp + 1;
            star_n += 1;
            n = star_n;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

const SearchState = struct {
    matches: usize = 0,
    scanned: u64 = 0,
    truncated: bool = false,
    lower_pat: []u8,
    /// Relative-time filter: entries older than this are skipped.
    min_mtime_ms: i64 = 0,
    max_matches: usize = MAX_MATCHES,
};

fn runSearch(allocator: std.mem.Allocator, spec: Spec, content: bool) u8 {
    if (spec.pattern.len == 0) return emitError("empty pattern");
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, true)) return emitErrno("stat root");
    if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return emitError("search root is not a directory");
    const lower = allocator.dupe(u8, spec.pattern) catch return emitError("out of memory");
    defer allocator.free(lower);
    for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);
    var state = SearchState{ .lower_pat = lower, .max_matches = matchCapOf(spec) };
    if (spec.within_ms > 0)
        state.min_mtime_ms = wallMs() - @as(i64, @intCast(@min(spec.within_ms, 1 << 50)));
    searchDir(allocator, spec.src, spec.pattern, content, &state);
    emit(.{
        .ev = "done",
        .done = state.scanned,
        .total = state.scanned,
        .matches = state.matches,
        .truncated = state.truncated,
    });
    return 0;
}

fn searchDir(allocator: std.mem.Allocator, dir_path: []const u8, pattern: []const u8, content: bool, state: *SearchState) void {
    if (state.matches >= state.max_matches) {
        state.truncated = true;
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const l = fsserve.listDir(arena_state.allocator(), dir_path, fsserve.MAX_ENTRIES) catch return;
    for (l.entries) |e| {
        if (state.matches >= state.max_matches) {
            state.truncated = true;
            return;
        }
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("{s}/{s}", .{ if (dir_path.len == 1) "" else dir_path, e.name }) catch continue;
        const full = w.buffered();
        if (!content) {
            const fresh = state.min_mtime_ms == 0 or e.mtime_ms >= state.min_mtime_ms;
            if (fresh and nameMatches(pattern, e.name)) {
                state.matches += 1;
                emit(.{ .ev = "match", .path = full, .kind = e.kind, .size = e.size, .mtime_ms = e.mtime_ms });
            }
        } else if (std.mem.eql(u8, e.kind, "file") and e.size <= MAX_GREP_FILE) {
            grepFile(full, state);
        }
        state.scanned += 1;
        if (state.scanned % 512 == 0)
            emit(.{ .ev = "progress", .done = state.scanned, .total = @as(u64, 0) });
        if (std.mem.eql(u8, e.kind, "dir"))
            searchDir(allocator, full, pattern, content, state);
    }
}

/// Output lines quoted back when they are not usable paths. The
/// COUNT on the done event is exact; this only bounds how many of
/// them travel as text.
const MAX_PANEL_REJECTS: usize = 20;

/// Turns a panelize command's output stream into rows. A line that
/// does not resolve to something on disk is REJECTED, never dropped:
/// commands print diagnostics, totals and "fatal: ..." on stdout too,
/// and a listing that silently swallows them is a listing you cannot
/// trust.
const PanelOut = struct {
    root: []const u8,
    max_matches: usize = MAX_MATCHES,
    matches: usize = 0,
    rejected: u64 = 0,
    quoted: usize = 0,
    truncated: bool = false,

    /// One delimited output item. Blank items are separator noise and
    /// count as nothing at all.
    fn take(self: *PanelOut, raw: []const u8) void {
        const value = std.mem.trim(u8, raw, " \t\r");
        if (value.len == 0) return;
        if (self.matches >= self.max_matches) {
            self.truncated = true;
            return;
        }
        if (panelizeOne(self.root, value)) {
            self.matches += 1;
            return;
        }
        self.rejected += 1;
        if (self.quoted < MAX_PANEL_REJECTS) {
            self.quoted += 1;
            emit(.{ .ev = "reject", .text = value[0..@min(value.len, MAX_MATCH_LINE)] });
        }
    }
};

/// Run an arbitrary host-side command and turn each LF- or NUL-delimited
/// output path into an operable result entry. Relative paths use `src` as cwd.
///
/// A nonzero exit is REPORTED (`exit_status` on the done event), not
/// treated as failure: `rg -l` exits 1 when nothing matched and `find`
/// exits 1 on an unreadable subdirectory, and in both cases the rows
/// that did arrive are the listing the user asked for.
fn runPanelize(spec: Spec) u8 {
    if (spec.pattern.len == 0) return emitError("panelize needs command");
    var cwdz: [4096]u8 = undefined;
    const cwd = pathz.pathZ(&cwdz, spec.src) catch return emitError("cwd too long");
    var cmdz: [16 * 1024:0]u8 = undefined;
    const cmd = std.fmt.bufPrintZ(&cmdz, "{s}", .{spec.pattern}) catch return emitError("command too long");
    var pipefd: [2]c_int = undefined;
    if (c.pipe(&pipefd) != 0) return emitErrno("pipe");
    const pid = c.fork();
    if (pid < 0) return emitErrno("fork");
    if (pid == 0) {
        _ = c.chdir(cwd);
        _ = c.dup2(pipefd[1], 1);
        _ = c.close(pipefd[0]);
        _ = c.close(pipefd[1]);
        const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-lc", cmd.ptr, null };
        _ = c.execv("/bin/sh", @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.close(pipefd[1]);
    var out = PanelOut{ .root = spec.src, .max_matches = matchCapOf(spec) };
    var item: [4096]u8 = undefined;
    var item_len: usize = 0;
    var overlong = false;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(pipefd[0], &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        for (buf[0..@intCast(n)]) |ch| {
            if (ch == '\n' or ch == 0) {
                // A truncated item would resolve to the WRONG file, so
                // the whole item is rejected rather than shortened.
                if (overlong) {
                    out.rejected += 1;
                    if (out.quoted < MAX_PANEL_REJECTS) {
                        out.quoted += 1;
                        emit(.{ .ev = "reject", .text = "output item longer than 4096 bytes" });
                    }
                } else out.take(item[0..item_len]);
                item_len = 0;
                overlong = false;
            } else if (item_len < item.len) {
                item[item_len] = ch;
                item_len += 1;
            } else overlong = true;
        }
    }
    if (item_len > 0 and !overlong) out.take(item[0..item_len]);
    _ = c.close(pipefd[0]);
    var st: c_int = 0;
    while (c.waitpid(pid, &st, 0) < 0 and std.posix.errno(@as(c_int, -1)) == .INTR) {}
    const status: i64 = if (c.WIFEXITED(st)) c.WEXITSTATUS(st) else -1;
    emit(.{
        .ev = "done",
        .done = out.matches,
        .total = out.matches,
        .matches = out.matches,
        .truncated = out.truncated,
        .rejected = out.rejected,
        .exit_status = status,
    });
    return 0;
}

/// Resolve one output item against the panel root and stream it as a
/// row. @return false when it does not name anything on disk.
fn panelizeOne(root: []const u8, value: []const u8) bool {
    var full_buf: [4096]u8 = undefined;
    const full = if (value[0] == '/')
        value
    else
        std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ if (root.len == 1) "" else root, value }) catch return false;
    var st: c.struct_stat = undefined;
    if (!statOf(full, &st, false)) return false;
    emit(.{
        .ev = "match",
        .path = full,
        .kind = fsserve.kindOf(st.st_mode),
        .size = if (st.st_size > 0) @as(u64, @intCast(st.st_size)) else 0,
        .mtime_ms = fsserve.mtimeMs(&st),
    });
    return true;
}

// ── live queries ────────────────────────────────────────────────

/// Directories watched at once. A recursive watch costs kernel memory
/// per directory, so a query over a huge tree stops adding watches --
/// and SAYS so on its status event rather than silently going deaf.
const MAX_LIVE_WATCHES: usize = 8192;

/// Longest a query with a relative-time predicate sleeps between
/// deadline checks. The sleep normally runs to the nearest expiry;
/// this only bounds how stale a wall-clock jump (NTP step, suspend,
/// DST) can leave the view.
const MAX_LIVE_SLEEP_MS: i64 = 5 * 60 * 1000;

const LiveWatch = struct { wd: c_int, path: []u8 };

/// A live filename query: the watch set, the paths currently matching,
/// and -- for a relative-time predicate -- when each of those stops
/// matching.
///
/// Time predicates are re-evaluated by DEADLINE, never by rescanning.
/// Every match knows the wall-clock instant its mtime leaves the
/// window; the poll sleeps until the nearest one, and the wakeup is an
/// integer scan of the tracked set with no readdir and no stat. A tree
/// is walked exactly once, at startup.
const LiveState = struct {
    allocator: std.mem.Allocator,
    watcher: *fsserve.Watcher,
    pattern: []const u8,
    /// 0 = no time predicate; matches then never expire.
    within_ms: u64 = 0,
    max_matches: usize = MAX_MATCHES,
    watches: std.ArrayList(LiveWatch) = .empty,
    /// Matching path -> expiry instant (0 = never). Owns its keys, and
    /// IS the row set the client is showing: the caps below are about
    /// this set, not about a cumulative count, so a query that runs
    /// for a week never truncates itself over churn.
    matched: std.StringHashMapUnmanaged(i64) = .empty,
    truncated: bool = false,
    watch_limit: bool = false,
    /// A bound was newly hit; the status event needs re-sending.
    status_dirty: bool = false,

    fn deinit(self: *LiveState) void {
        for (self.watches.items) |w| self.allocator.free(w.path);
        self.watches.deinit(self.allocator);
        var it = self.matched.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.matched.deinit(self.allocator);
    }

    /// The instant a file with this mtime leaves the query window
    /// (0 = there is no window).
    fn expiryOf(self: *const LiveState, mtime_ms: i64) i64 {
        if (self.within_ms == 0) return 0;
        return mtime_ms +| @as(i64, @intCast(@min(self.within_ms, 1 << 50)));
    }

    fn fresh(self: *const LiveState, mtime_ms: i64, now: i64) bool {
        return self.within_ms == 0 or self.expiryOf(mtime_ms) > now;
    }

    fn pathOf(self: *const LiveState, wd: c_int) ?[]const u8 {
        for (self.watches.items) |w| {
            if (w.wd == wd) return w.path;
        }
        return null;
    }

    /// Stream one match, or refresh a row already on screen. Repeating
    /// a match is deliberate: the client upserts by path, so a write
    /// that changed size or mtime updates the row in place.
    fn add(self: *LiveState, path: []const u8, kind: []const u8, size: u64, mtime_ms: i64) void {
        const expiry = self.expiryOf(mtime_ms);
        if (self.matched.getPtr(path)) |slot| {
            slot.* = expiry;
        } else {
            if (self.matched.count() >= self.max_matches) {
                if (!self.truncated) {
                    self.truncated = true;
                    self.status_dirty = true;
                }
                return;
            }
            const owned = self.allocator.dupe(u8, path) catch return;
            self.matched.put(self.allocator, owned, expiry) catch {
                self.allocator.free(owned);
                return;
            };
        }
        emit(.{ .ev = "match", .path = path, .kind = kind, .size = size, .mtime_ms = mtime_ms });
    }

    /// Drop exactly `path`. Silent when it was not a match: an unmatch
    /// for a row the client never had is pure noise.
    fn removeOne(self: *LiveState, path: []const u8) void {
        const kv = self.matched.fetchRemove(path) orelse return;
        emit(.{ .ev = "unmatch", .path = kv.key });
        self.allocator.free(kv.key);
    }

    /// Drop `path` AND everything under it. A directory moved out of
    /// the tree delivers no per-child event, so its rows would
    /// otherwise linger forever under a name that no longer exists.
    fn removeTree(self: *LiveState, path: []const u8) void {
        self.removeOne(path);
        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(self.allocator);
        var it = self.matched.keyIterator();
        while (it.next()) |k| {
            const key = k.*;
            if (key.len > path.len and std.mem.startsWith(u8, key, path) and key[path.len] == '/')
                doomed.append(self.allocator, key) catch {};
        }
        for (doomed.items) |key| self.removeOne(key);
        self.dropWatchesUnder(path);
    }

    fn dropWatchesUnder(self: *LiveState, path: []const u8) void {
        var i: usize = 0;
        while (i < self.watches.items.len) {
            const w = self.watches.items[i];
            const under = std.mem.eql(u8, w.path, path) or
                (w.path.len > path.len and std.mem.startsWith(u8, w.path, path) and w.path[path.len] == '/');
            if (!under) {
                i += 1;
                continue;
            }
            self.watcher.remove(w.wd);
            self.allocator.free(w.path);
            _ = self.watches.swapRemove(i);
        }
    }

    /// Drop every match whose time predicate has run out.
    fn expire(self: *LiveState, now: i64) void {
        if (self.within_ms == 0) return;
        var doomed: std.ArrayList([]const u8) = .empty;
        defer doomed.deinit(self.allocator);
        var it = self.matched.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* != 0 and kv.value_ptr.* <= now)
                doomed.append(self.allocator, kv.key_ptr.*) catch {};
        }
        for (doomed.items) |key| self.removeOne(key);
    }

    /// Poll timeout: milliseconds until the earliest match ages out.
    /// -1 (sleep forever) whenever there is no time predicate at all.
    fn sleepMs(self: *const LiveState, now: i64) c_int {
        if (self.within_ms == 0) return -1;
        var soonest: i64 = 0;
        var it = self.matched.valueIterator();
        while (it.next()) |v| {
            if (v.* == 0) continue;
            if (soonest == 0 or v.* < soonest) soonest = v.*;
        }
        if (soonest == 0) return @intCast(MAX_LIVE_SLEEP_MS);
        const delta = soonest - now;
        if (delta <= 0) return 0;
        return @intCast(@min(delta, MAX_LIVE_SLEEP_MS));
    }

    /// The query's status line: rows streamed, directories watched, and
    /// whether either bound was hit. Sent once the initial scan is done
    /// and again whenever a bound is newly reached.
    fn emitStatus(self: *LiveState) void {
        self.status_dirty = false;
        emit(.{
            .ev = "ready",
            .matches = self.matched.count(),
            .watches = self.watches.items.len,
            .truncated = self.truncated,
            .watch_limit = self.watch_limit,
        });
    }
};

/// Watch `path`, stream the entries in it that match, and recurse.
fn liveScanDir(st: *LiveState, path: []const u8) void {
    if (st.watches.items.len >= MAX_LIVE_WATCHES) {
        if (!st.watch_limit) {
            st.watch_limit = true;
            st.status_dirty = true;
        }
        return;
    }
    var z: [4096]u8 = undefined;
    const pz = pathz.pathZ(&z, path) catch return;
    const wd = st.watcher.add(pz);
    if (wd < 0) {
        // A refused watch is not the same as an empty one. When the
        // backend is out of capacity (kqueue's fd budget, inotify's
        // max_user_watches) this directory AND everything below it go
        // unwatched, and the query keeps streaming as if it were live.
        // A partial live view that says it is partial is usable; one
        // that stays quiet is a wrong answer with no symptom.
        if (st.watcher.exhausted and !st.watch_limit) {
            st.watch_limit = true;
            st.status_dirty = true;
        }
        return;
    }
    // inotify hands back the SAME descriptor for a directory already
    // watched, which is how re-entering a known subtree costs nothing.
    for (st.watches.items) |w| {
        if (w.wd == wd) return;
    }
    const owned = st.allocator.dupe(u8, path) catch return;
    st.watches.append(st.allocator, .{ .wd = wd, .path = owned }) catch {
        st.allocator.free(owned);
        return;
    };
    var arena = std.heap.ArenaAllocator.init(st.allocator);
    defer arena.deinit();
    const listing = fsserve.listDir(arena.allocator(), path, fsserve.MAX_ENTRIES) catch return;
    const now = wallMs();
    for (listing.entries) |e| {
        var full_buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ if (path.len == 1) "" else path, e.name }) catch continue;
        if (nameMatches(st.pattern, e.name) and st.fresh(e.mtime_ms, now))
            st.add(full, e.kind, e.size, e.mtime_ms);
        if (std.mem.eql(u8, e.kind, "dir")) liveScanDir(st, full);
    }
}

/// Durable Haiku-style live filename query, watching the tree
/// recursively: inotify on Linux, kqueue on macOS (see fsserve.Watcher
/// for the one event the latter cannot see). A host with neither
/// reports the missing watcher honestly instead of polling.
fn runLiveFind(allocator: std.mem.Allocator, spec: Spec) u8 {
    if (spec.pattern.len == 0) return emitError("live_find needs pattern");
    var watcher: fsserve.Watcher = .{};
    defer watcher.deinit();
    if (!watcher.ensure()) return emitError("cannot create filesystem watcher");
    var st = LiveState{
        .allocator = allocator,
        .watcher = &watcher,
        .pattern = spec.pattern,
        .within_ms = spec.within_ms,
        .max_matches = matchCapOf(spec),
    };
    defer st.deinit();
    liveScanDir(&st, spec.src);
    st.emitStatus();
    var buf: [32 * 1024]u8 = undefined;
    while (true) {
        // stdout rides the poll set purely for its hangup: a copy keeps
        // running when the daemon dies (durability), but a live query
        // with no one left to stream to is a recursive watcher held
        // open forever for nobody.
        var pfds = [_]c.struct_pollfd{
            .{ .fd = watcher.fd, .events = c.POLLIN, .revents = 0 },
            .{ .fd = 1, .events = 0, .revents = 0 },
        };
        const pr = c.poll(&pfds, 2, st.sleepMs(wallMs()));
        if (pr < 0) {
            if (std.posix.errno(pr) == .INTR) continue;
            return emitError("watcher poll failed");
        }
        if (pfds[1].revents & (c.POLLERR | c.POLLHUP | c.POLLNVAL) != 0) return 0;
        if (pfds[0].revents != 0) {
            const n = watcher.readInto(&buf);
            if (n < 0 and std.posix.errno(n) == .INTR) continue;
            if (n <= 0) return emitError("watcher read failed");
            var it = fsserve.EventIter{ .buf = buf[0..@intCast(n)] };
            while (it.next()) |ev| liveEvent(&st, ev);
        }
        // Checked after an event batch too, not just after a timeout:
        // a busy tree can keep the poll returning readable straight
        // through a deadline.
        st.expire(wallMs());
        if (st.status_dirty) st.emitStatus();
    }
}

fn liveEvent(st: *LiveState, ev: fsserve.InoEvent) void {
    if (ev.isOverflow()) return emit(.{ .ev = "resync" });
    const parent = st.pathOf(ev.wd) orelse return;
    // removeTree frees the watch paths, so the parent has to be copied
    // out before anything can invalidate it.
    var parent_buf: [4096]u8 = undefined;
    if (parent.len > parent_buf.len) return;
    @memcpy(parent_buf[0..parent.len], parent);
    const dir = parent_buf[0..parent.len];
    if (ev.isSelfGone()) return st.removeTree(dir);
    if (ev.name.len == 0) return;

    var full_buf: [4096]u8 = undefined;
    const full = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ if (dir.len == 1) "" else dir, ev.name }) catch return;
    var z: [4096]u8 = undefined;
    const fz = pathz.pathZ(&z, full) catch return;
    var stt: c.struct_stat = undefined;
    if (c.lstat(fz, &stt) != 0) return st.removeTree(full);
    const kind = fsserve.kindOf(stt.st_mode);
    const mtime_ms = fsserve.mtimeMs(&stt);
    if (nameMatches(st.pattern, ev.name) and st.fresh(mtime_ms, wallMs())) {
        st.add(full, kind, if (stt.st_size > 0) @as(u64, @intCast(stt.st_size)) else 0, mtime_ms);
    } else {
        // Only this entry stopped matching. Its children (a directory
        // that never matched the pattern still holds matching files)
        // are untouched.
        st.removeOne(full);
    }
    // A directory that appeared -- or that was moved in under a new
    // name -- has to be watched and listed, matching or not.
    if (std.mem.eql(u8, kind, "dir")) liveScanDir(st, full);
}

/// Line-based case-insensitive content scan; binary files (NUL in
/// the first 4KB) are skipped.
fn grepFile(path: []const u8, state: *SearchState) void {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return;
    const fd = c.open(p, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return;
    defer _ = c.close(fd);

    var buf: [64 * 1024]u8 = undefined;
    var carry: [MAX_MATCH_LINE]u8 = undefined;
    var carry_len: usize = 0;
    var line_no: u64 = 1;
    var file_matches: usize = 0;
    var first = true;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        const chunk = buf[0..@intCast(n)];
        if (first) {
            first = false;
            const probe = chunk[0..@min(chunk.len, 4096)];
            if (std.mem.indexOfScalar(u8, probe, 0) != null) return; // binary
        }
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, chunk, start, '\n')) |nl| {
            const tail = chunk[start..nl];
            if (matchLine(state, path, line_no, carry[0..carry_len], tail)) {
                file_matches += 1;
                if (file_matches >= MAX_MATCHES_PER_FILE or state.matches >= MAX_MATCHES) return;
            }
            carry_len = 0;
            line_no += 1;
            start = nl + 1;
        }
        const rest = chunk[start..];
        const room = carry.len - carry_len;
        const take = @min(rest.len, room);
        @memcpy(carry[carry_len .. carry_len + take], rest[0..take]);
        carry_len += take;
        // A line longer than the carry buffer: the head is enough for
        // matching/preview; the overflow is dropped by design.
    }
    if (carry_len > 0)
        _ = matchLine(state, path, line_no, carry[0..carry_len], "");
}

fn matchLine(state: *SearchState, path: []const u8, line_no: u64, head: []const u8, tail: []const u8) bool {
    var line_buf: [MAX_MATCH_LINE]u8 = undefined;
    const hn = @min(head.len, line_buf.len);
    @memcpy(line_buf[0..hn], head[0..hn]);
    const tn = @min(tail.len, line_buf.len - hn);
    @memcpy(line_buf[hn .. hn + tn], tail[0..tn]);
    const line = line_buf[0 .. hn + tn];
    for (line) |*ch| {
        if (ch.* == '\r' or ch.* == '\t') ch.* = ' ';
    }
    var lower_buf: [MAX_MATCH_LINE]u8 = undefined;
    for (line, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    if (std.mem.indexOf(u8, lower_buf[0..line.len], state.lower_pat) == null) return false;
    // Strip non-printable control bytes for the preview.
    for (line) |*ch| {
        if (ch.* < 0x20) ch.* = ' ';
    }
    state.matches += 1;
    emit(.{ .ev = "match", .path = path, .line = line_no, .text = line });
    return true;
}

// ── hash ────────────────────────────────────────────────────────

fn hashPrefix(path: []const u8, limit: u64, progress: ?*Progress) ?[Sha256.digest_length]u8 {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return null;
    const fd = c.open(p, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var h = Sha256.init(.{});
    var buf: [CHUNK]u8 = undefined;
    var left = limit;
    while (left > 0) {
        const want: usize = @intCast(@min(left, buf.len));
        const n = c.read(fd, &buf, want);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        h.update(buf[0..@intCast(n)]);
        left -= @intCast(n);
        if (progress) |pr| if (!pr.add(@intCast(n))) return null;
    }
    if (left != 0) return null; // short file
    var out: [Sha256.digest_length]u8 = undefined;
    h.final(&out);
    return out;
}

fn runHash(spec: Spec) u8 {
    var st: c.struct_stat = undefined;
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, spec.src) catch return emitError("path too long");
    if (c.stat(p, &st) != 0) return emitErrno("stat");
    const size: u64 = if (st.st_size > 0) @intCast(st.st_size) else 0;
    var progress = Progress{ .total = size };
    const digest = hashPrefix(spec.src, size, &progress) orelse return emitErrno("read");
    var hex: [Sha256.digest_length * 2]u8 = undefined;
    for (digest, 0..) |b, i| {
        _ = std.fmt.bufPrint(hex[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    }
    emit(.{ .ev = "done", .done = size, .total = size, .hash = hex[0..] });
    return 0;
}

// ── copy ────────────────────────────────────────────────────────

fn statOf(path: []const u8, st: *c.struct_stat, follow: bool) bool {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return false;
    return (if (follow) c.stat(p, st) else c.lstat(p, st)) == 0;
}

fn fsyncParent(path: []const u8) bool {
    const parent = std.fs.path.dirname(path) orelse return false;
    var z: [4096]u8 = undefined;
    const dfd = c.open(pathz.pathZ(&z, parent) catch return false, c.O_RDONLY | c.O_DIRECTORY);
    if (dfd < 0) return false;
    defer _ = c.close(dfd);
    return c.fsync(dfd) == 0;
}

fn runCopy(allocator: std.mem.Allocator, spec: Spec) u8 {
    if (spec.dst.len == 0) return emitError("copy needs dst");
    // dst inside src would recurse into its own output.
    if (spec.dst.len > spec.src.len and
        std.mem.startsWith(u8, spec.dst, spec.src) and spec.dst[spec.src.len] == '/')
        return emitError("dst is inside src");

    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return emitErrno("stat src");

    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) return runCopyTree(allocator, spec);
    if ((st.st_mode & c.S_IFMT) == c.S_IFLNK) return runCopyRootLink(spec);

    var progress = Progress{
        .total = if (st.st_size > 0) @intCast(st.st_size) else 0,
        .entries_total = 1,
    };
    switch (copyOneFile(spec.src, spec.dst, st, spec.@"resume", spec.verify, spec.no_replace, &progress)) {
        .ok => if (!progress.entryDone()) return emitError("file-count overflow"),
        .err => |m| return emitError(m),
        .errno => |what| return emitErrno(what),
    }
    emitCopyDone(&progress);
    return 0;
}

fn runCopyRootLink(spec: Spec) u8 {
    var src_z: [4096]u8 = undefined;
    const src = pathz.pathZ(&src_z, spec.src) catch return emitError("path too long");
    var target_buf: [4096]u8 = undefined;
    const n = c.readlink(src, &target_buf, target_buf.len);
    if (n < 0) return emitErrno("readlink");
    var temp_buf: [4096]u8 = undefined;
    const temp = std.fmt.bufPrint(&temp_buf, "{s}.skpart-link-{d}", .{ spec.dst, c.getpid() }) catch
        return emitError("path too long");
    var temp_z_buf: [4096]u8 = undefined;
    const temp_z = pathz.pathZ(&temp_z_buf, temp) catch return emitError("path too long");
    _ = c.unlink(temp_z);
    if (c.symlink(pathz.pathZ(&src_z, target_buf[0..@intCast(n)]) catch return emitError("symlink target too long"), temp_z) != 0)
        return emitErrno("create symlink");
    var dst_z_buf: [4096]u8 = undefined;
    const dst_z = pathz.pathZ(&dst_z_buf, spec.dst) catch return emitError("path too long");
    if (spec.no_replace) {
        switch (platform.renameNoReplace(temp_z, dst_z)) {
            .ok => {},
            .exists => {
                _ = c.unlink(temp_z);
                return emitError("destination exists");
            },
            .cross_device => {
                _ = c.unlink(temp_z);
                return emitError("install symlink crossed filesystems");
            },
            .failed => {
                _ = c.unlink(temp_z);
                return emitError("install symlink failed");
            },
        }
    } else if (c.rename(temp_z, dst_z) != 0) {
        _ = c.unlink(temp_z);
        return emitErrno("replace symlink");
    }
    if (!fsyncParent(spec.dst)) return emitErrno("fsync symlink parent");
    const progress = Progress{ .entries_done = 1, .entries_total = 1 };
    emitCopyDone(&progress);
    return 0;
}

/// Terminal event of a copy job. Its shape is shared by the file and
/// the tree path so the two can never drift.
fn emitCopyDone(progress: *const Progress) void {
    emit(.{
        .ev = "done",
        .done = progress.done,
        .total = progress.total,
        .resumed_from = progress.resumed,
        .files_done = progress.entries_done,
        .files_total = progress.entries_total,
    });
}

const CopyResult = union(enum) { ok, err: []const u8, errno: []const u8 };

/// What a tree copy does about names that already exist at the
/// destination. `replace` is a property of the TOP-level directory
/// only; nested collisions are always resolved per entry.
const CopyOpts = struct {
    allow_resume: bool = false,
    conflict: enum { overwrite, skip, keep_both } = .overwrite,
    replace: bool = false,
    verify: bool = false,
    no_replace: bool = false,

    fn fromSpec(spec: Spec) CopyOpts {
        return .{
            .allow_resume = spec.@"resume",
            .verify = spec.verify,
            .conflict = if (std.mem.eql(u8, spec.conflict, "skip"))
                .skip
            else if (std.mem.eql(u8, spec.conflict, "keep_both"))
                .keep_both
            else
                .overwrite,
            .replace = std.mem.eql(u8, spec.dir_mode, "replace"),
            .no_replace = spec.no_replace,
        };
    }
};

/// Single-file copy via a staged `.skpart` with hash-verified resume,
/// fsync, mode preservation, and atomic rename.
fn copyOneFile(src: []const u8, dst: []const u8, src_st: c.struct_stat, allow_resume: bool, verify: bool, no_replace: bool, progress: *Progress) CopyResult {
    var part_buf: [4096]u8 = undefined;
    var wpart = std.Io.Writer.fixed(&part_buf);
    wpart.print("{s}.skpart", .{dst}) catch return .{ .err = "path too long" };
    const part = wpart.buffered();

    const src_size: u64 = if (src_st.st_size > 0) @intCast(src_st.st_size) else 0;

    // Resume decision: an existing partial continues only when its
    // FULL content hashes equal to the same-length source prefix.
    var start: u64 = 0;
    if (allow_resume) {
        var pst: c.struct_stat = undefined;
        if (statOf(part, &pst, true) and pst.st_size > 0 and @as(u64, @intCast(pst.st_size)) <= src_size) {
            const plen: u64 = @intCast(pst.st_size);
            const part_h = hashPrefix(part, plen, null);
            const src_h = hashPrefix(src, plen, null);
            if (part_h != null and src_h != null and
                std.mem.eql(u8, &part_h.?, &src_h.?)) start = plen;
        }
    }
    // Cumulative, not assigned: inside a tree copy `done` already
    // carries every earlier file (assigning here made the panel's
    // percentage restart from zero on every file of a tree).
    progress.resumed = std.math.add(u64, progress.resumed, start) catch
        return .{ .err = "copy progress overflow" };
    progress.done = std.math.add(u64, progress.done, start) catch
        return .{ .err = "copy progress overflow" };
    progress.setFile(src);

    var zs: [4096]u8 = undefined;
    const sp = pathz.pathZ(&zs, src) catch return .{ .err = "path too long" };
    const sfd = c.open(sp, c.O_RDONLY | c.O_CLOEXEC);
    if (sfd < 0) return .{ .errno = "open src" };
    defer _ = c.close(sfd);

    var zd: [4096]u8 = undefined;
    const pp = pathz.pathZ(&zd, part) catch return .{ .err = "path too long" };
    const dflags: c_int = if (start > 0) c.O_WRONLY | c.O_CLOEXEC else c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC;
    const dfd = c.open(pp, dflags, @as(c.mode_t, 0o600));
    if (dfd < 0) return .{ .errno = "open dst" };
    defer _ = c.close(dfd);
    if (start > 0) {
        if (c.lseek(dfd, @intCast(start), c.SEEK_SET) < 0) return .{ .errno = "seek dst" };
        if (c.lseek(sfd, @intCast(start), c.SEEK_SET) < 0) return .{ .errno = "seek src" };
    }

    var buf: [CHUNK]u8 = undefined;
    while (true) {
        const n = c.read(sfd, &buf, buf.len);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n < 0) return .{ .errno = "read src" };
        if (n == 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(n))) {
            const w = c.write(dfd, buf[off..].ptr, @as(usize, @intCast(n)) - off);
            if (w < 0 and std.posix.errno(w) == .INTR) continue;
            if (w <= 0) return .{ .errno = "write dst" };
            off += @intCast(w);
        }
        if (!progress.add(@intCast(n))) return .{ .err = "copy progress overflow" };
    }

    if (c.fsync(dfd) != 0) return .{ .errno = "fsync" };
    _ = c.fchmod(dfd, src_st.st_mode & 0o7777);
    // Verify-after-copy: the staged bytes must hash like the source
    // BEFORE the rename installs them; a mismatch leaves the
    // destination untouched and discards the stage.
    if (verify) {
        const part_h = hashPrefix(part, src_size, null);
        const src_h = hashPrefix(src, src_size, null);
        if (part_h == null or src_h == null or !std.mem.eql(u8, &part_h.?, &src_h.?)) {
            _ = c.unlink(pp);
            return .{ .err = "copy verification failed (checksum mismatch)" };
        }
    }
    var zr: [4096]u8 = undefined;
    const dp = pathz.pathZ(&zr, dst) catch return .{ .err = "path too long" };
    if (no_replace) {
        switch (platform.renameNoReplace(pp, dp)) {
            .ok => {},
            .exists => {
                _ = c.unlink(pp);
                return .{ .err = "destination exists" };
            },
            .cross_device => {
                _ = c.unlink(pp);
                return .{ .err = "install destination crossed filesystems" };
            },
            .failed => {
                _ = c.unlink(pp);
                return .{ .err = "install destination failed" };
            },
        }
    } else if (c.rename(pp, dp) != 0) return .{ .errno = "rename" };
    if (!fsyncParent(dst)) return .{ .errno = "fsync destination parent" };
    return .ok;
}

/// Recursive tree copy. Pass 1 sizes the job (progress totals);
/// pass 2 copies: dirs mkdir'ed, symlinks recreated as symlinks,
/// regular files staged like the single-file path. On resume,
/// completed files are reused only after source/destination hashing;
/// the in-flight partial is likewise prefix-verified before resume.
///
/// A destination directory that already exists is MERGED by default:
/// the walk recurses into it and entries that exist only there are
/// left alone. `dir_mode = "replace"` deletes the destination tree
/// first, so those entries are gone.
fn runCopyTree(allocator: std.mem.Allocator, spec: Spec) u8 {
    var progress = Progress{};
    var before_hash = Sha256.init(.{});
    if (!sizeTree(allocator, spec.src, &progress.total, &progress.entries_total, &before_hash))
        return emitError("cannot size source tree (listing failed or truncated)");
    var before: [Sha256.digest_length]u8 = undefined;
    before_hash.final(&before);

    const opts = CopyOpts.fromSpec(spec);
    if (opts.no_replace and opts.replace)
        return emitError("no_replace conflicts with dir_mode=replace");
    if (opts.replace) {
        var dst_st: c.struct_stat = undefined;
        if (statOf(spec.dst, &dst_st, false)) {
            var drop = Progress{ .quiet = true };
            const removed = if ((dst_st.st_mode & c.S_IFMT) == c.S_IFDIR)
                deleteTreeDir(spec.dst, &drop)
            else blk: {
                var z: [4096]u8 = undefined;
                break :blk c.unlink(pathz.pathZ(&z, spec.dst) catch
                    return emitError("path too long")) == 0;
            };
            if (!removed) return emitErrno("replace destination");
        }
    }
    switch (copyTreeDir(allocator, spec.src, spec.dst, opts, &progress, true)) {
        .ok => {},
        .err => |m| return emitError(m),
        .errno => |what| return emitErrno(what),
    }
    if (progress.done != progress.total or progress.entries_done != progress.entries_total)
        return emitError("source tree changed while it was copied; progress manifest drifted");
    var after_total: u64 = 0;
    var after_files: u64 = 0;
    var after_hash = Sha256.init(.{});
    if (!sizeTree(allocator, spec.src, &after_total, &after_files, &after_hash))
        return emitError("source tree changed while it was copied; final listing failed");
    var after: [Sha256.digest_length]u8 = undefined;
    after_hash.final(&after);
    if (after_total != progress.total or after_files != progress.entries_total or
        !std.mem.eql(u8, &before, &after))
        return emitError("source tree changed while it was copied; source fingerprint drifted");
    emitCopyDone(&progress);
    return 0;
}

fn stampU64(hash: *Sha256, value: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    hash.update(&buf);
}

fn stampEntry(hash: *Sha256, path: []const u8, kind: []const u8, size: u64, mode: u32, mtime_ns: i64, ctime_ns: i64, dev: u64, ino: u64, target: []const u8) void {
    stampU64(hash, path.len);
    hash.update(path);
    stampU64(hash, kind.len);
    hash.update(kind);
    stampU64(hash, size);
    stampU64(hash, mode);
    stampU64(hash, @bitCast(mtime_ns));
    stampU64(hash, @bitCast(ctime_ns));
    stampU64(hash, dev);
    stampU64(hash, ino);
    stampU64(hash, target.len);
    hash.update(target);
}

fn sizeTree(allocator: std.mem.Allocator, dir_path: []const u8, total: *u64, files: *u64, hash: *Sha256) bool {
    var dir_st: c.struct_stat = undefined;
    if (!statOf(dir_path, &dir_st, false)) return false;
    const dir_mtime = if (@hasField(c.struct_stat, "st_mtim")) dir_st.st_mtim else dir_st.st_mtimespec;
    const dir_ctime = if (@hasField(c.struct_stat, "st_ctim")) dir_st.st_ctim else dir_st.st_ctimespec;
    stampEntry(hash, dir_path, "dir", 0, @intCast(dir_st.st_mode & 0o7777), @as(i64, @intCast(dir_mtime.tv_sec)) * std.time.ns_per_s + @as(i64, @intCast(dir_mtime.tv_nsec)), @as(i64, @intCast(dir_ctime.tv_sec)) * std.time.ns_per_s + @as(i64, @intCast(dir_ctime.tv_nsec)), @intCast(dir_st.st_dev), @intCast(dir_st.st_ino), "");
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const l = fsserve.listDir(arena_state.allocator(), dir_path, fsserve.MAX_ENTRIES) catch return false;
    if (l.truncated) return false;
    for (l.entries) |e| {
        var buf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        w.print("{s}/{s}", .{ dir_path, e.name }) catch return false;
        const child = w.buffered();
        stampEntry(hash, child, e.kind, e.size, e.mode, e.mtime_ns, e.ctime_ns, e.dev, e.ino, e.target orelse "");
        if (std.mem.eql(u8, e.kind, "dir")) {
            if (!sizeTree(allocator, child, total, files, hash)) return false;
        } else if (std.mem.eql(u8, e.kind, "file")) {
            total.* = std.math.add(u64, total.*, e.size) catch return false;
            files.* = std.math.add(u64, files.*, 1) catch return false;
        }
    }
    return true;
}

/// A destination name that is free in `dir`, "name-copy" first —
/// the same scheme the browser's own Keep Both uses.
fn uniqueInDir(dir: []const u8, base: []const u8, buf: []u8) ?[]const u8 {
    const OnDisk = struct {
        dir: []const u8,
        pub fn contains(self: @This(), name: []const u8) bool {
            var full: [4096]u8 = undefined;
            var z: [4096]u8 = undefined;
            const p = std.fmt.bufPrint(&full, "{s}/{s}", .{ if (self.dir.len == 1) "" else self.dir, name }) catch return true;
            var st: c.struct_stat = undefined;
            return c.lstat(pathz.pathZ(&z, p) catch return true, &st) == 0;
        }
    };
    return uniqueName(base, buf, OnDisk{ .dir = dir });
}

fn copyTreeDir(allocator: std.mem.Allocator, src_dir: []const u8, dst_dir: []const u8, opts: CopyOpts, progress: *Progress, root: bool) CopyResult {
    var src_st: c.struct_stat = undefined;
    if (!statOf(src_dir, &src_st, true)) return .{ .errno = "stat dir" };
    {
        var z: [4096]u8 = undefined;
        const dp = pathz.pathZ(&z, dst_dir) catch return .{ .err = "path too long" };
        const rc = c.mkdir(dp, src_st.st_mode & 0o7777);
        if (rc == 0) {
            if (!fsyncParent(dst_dir)) return .{ .errno = "fsync directory parent" };
        } else if (std.posix.errno(@as(c_int, -1)) == .EXIST) {
            if (root and opts.no_replace) return .{ .err = "destination exists" };
            var st2: c.struct_stat = undefined;
            if (c.stat(dp, &st2) != 0 or (st2.st_mode & c.S_IFMT) != c.S_IFDIR) return .{ .errno = "mkdir" };
        } else return .{ .errno = "mkdir" };
    }

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const l = fsserve.listDir(arena_state.allocator(), src_dir, fsserve.MAX_ENTRIES) catch
        return .{ .err = "cannot list source dir" };
    if (l.truncated) return .{ .err = "source directory listing truncated" };

    for (l.entries) |e| {
        var sbuf: [4096]u8 = undefined;
        var sw = std.Io.Writer.fixed(&sbuf);
        sw.print("{s}/{s}", .{ src_dir, e.name }) catch return .{ .err = "path too long" };
        const spath = sw.buffered();
        var dbuf: [4096]u8 = undefined;
        var dw = std.Io.Writer.fixed(&dbuf);
        dw.print("{s}/{s}", .{ dst_dir, e.name }) catch return .{ .err = "path too long" };
        var dpath = dw.buffered();

        // Per-entry collision policy. Directories are exempt: merging
        // recurses into them, which is what makes merge a merge.
        var unique_buf: [4096]u8 = undefined;
        if (opts.conflict != .overwrite and !std.mem.eql(u8, e.kind, "dir")) {
            var exist_st: c.struct_stat = undefined;
            if (statOf(dpath, &exist_st, false)) {
                if (opts.conflict == .skip) {
                    // Counted as handled: `total` already includes it,
                    // so not counting it would strand the bar short.
                    if (std.mem.eql(u8, e.kind, "file") and !progress.add(e.size))
                        return .{ .err = "copy progress overflow" };
                    if (!progress.entryDone()) return .{ .err = "file-count overflow" };
                    continue;
                }
                const name = uniqueInDir(dst_dir, e.name, &unique_buf) orelse
                    return .{ .err = "no free destination name" };
                var rw = std.Io.Writer.fixed(&dbuf);
                rw.print("{s}/{s}", .{ dst_dir, name }) catch return .{ .err = "path too long" };
                dpath = rw.buffered();
            }
        }

        if (std.mem.eql(u8, e.kind, "dir")) {
            switch (copyTreeDir(allocator, spath, dpath, opts, progress, false)) {
                .ok => {},
                else => |r| return r,
            }
        } else if (std.mem.eql(u8, e.kind, "link")) {
            var zt: [4096]u8 = undefined;
            var zl: [4096]u8 = undefined;
            var ztmp: [4096]u8 = undefined;
            const tgt = pathz.pathZ(&zt, e.target orelse return .{ .err = "symlink target missing" }) catch
                return .{ .err = "path too long" };
            const lp = pathz.pathZ(&zl, dpath) catch return .{ .err = "path too long" };
            var temp_buf: [4096]u8 = undefined;
            const temp = std.fmt.bufPrint(&temp_buf, "{s}.skpart-link-{d}", .{ dpath, c.getpid() }) catch return .{ .err = "path too long" };
            const temp_z = pathz.pathZ(&ztmp, temp) catch return .{ .err = "path too long" };
            _ = c.unlink(temp_z);
            if (c.symlink(tgt, temp_z) != 0) return .{ .errno = "create symlink" };
            if (c.rename(temp_z, lp) != 0) {
                _ = c.unlink(temp_z);
                return .{ .errno = "replace symlink" };
            }
            const parent = std.fs.path.dirname(dpath) orelse dst_dir;
            var zd: [4096]u8 = undefined;
            const dfd = c.open(pathz.pathZ(&zd, parent) catch return .{ .err = "path too long" }, c.O_RDONLY | c.O_DIRECTORY);
            if (dfd < 0) return .{ .errno = "open symlink parent" };
            defer _ = c.close(dfd);
            if (c.fsync(dfd) != 0) return .{ .errno = "fsync symlink parent" };
        } else if (std.mem.eql(u8, e.kind, "file")) {
            progress.setFile(spath);
            if (opts.allow_resume) {
                var dst_st: c.struct_stat = undefined;
                if (statOf(dpath, &dst_st, false) and (dst_st.st_mode & c.S_IFMT) == c.S_IFREG and
                    @as(u64, @intCast(dst_st.st_size)) == e.size)
                {
                    const src_h = hashPrefix(spath, e.size, null);
                    const dst_h = hashPrefix(dpath, e.size, null);
                    if (src_h != null and dst_h != null and std.mem.eql(u8, &src_h.?, &dst_h.?)) {
                        progress.resumed = std.math.add(u64, progress.resumed, e.size) catch
                            return .{ .err = "copy progress overflow" };
                        if (!progress.add(e.size) or !progress.entryDone())
                            return .{ .err = "copy progress overflow" };
                        continue;
                    }
                }
            }
            var fst: c.struct_stat = undefined;
            if (!statOf(spath, &fst, true)) return .{ .errno = "stat source file" };
            // Only regular files are counted: `entries_total` comes
            // from sizeTree, which counts exactly those.
            switch (copyOneFile(spath, dpath, fst, opts.allow_resume, opts.verify, false, progress)) {
                .ok => if (!progress.entryDone()) return .{ .err = "file-count overflow" },
                else => |r| return r,
            }
        }
        // "other" (sockets, fifos): skipped by design.
    }
    return .ok;
}

// ── delete_tree ─────────────────────────────────────────────────

fn runDeleteTree(spec: Spec) u8 {
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return emitErrno("stat");
    var progress = Progress{};
    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
        // Count first (a stat walk, cheap against the unlink storm to
        // come) so the panel can show a fraction rather than a
        // number climbing toward an unknown ceiling.
        var bytes: u64 = 0;
        var entries: u64 = 0;
        dirSizeWalk(spec.src, &bytes, &entries, false);
        progress.total = entries + 1; // + the root directory itself
        progress.entries_total = progress.total;
        if (!deleteTreeDir(spec.src, &progress)) return emitErrno("delete");
    } else {
        progress.entries_total = 1;
        progress.total = 1;
        progress.setFile(spec.src);
        var z: [4096]u8 = undefined;
        const p = pathz.pathZ(&z, spec.src) catch return emitError("path too long");
        if (c.unlink(p) != 0) return emitErrno("unlink");
        progress.done += 1;
        if (!progress.entryDone()) return emitError("file-count overflow");
    }
    emit(.{
        .ev = "done",
        .done = progress.done,
        .total = progress.done,
        .resumed_from = @as(u64, 0),
        .files_done = progress.entries_done,
        .files_total = progress.entries_done,
    });
    return 0;
}

/// Post-order removal. Progress counts ENTRIES (files + dirs), since
/// byte totals mean nothing for deletion. Stack-recursive over path
/// depth (bounded by PATH_MAX/2 components).
fn deleteTreeDir(dir_path: []const u8, progress: *Progress) bool {
    var z: [4096]u8 = undefined;
    const dz = pathz.pathZ(&z, dir_path) catch return false;
    const dir = c.opendir(dz) orelse return false;
    // Collect names first: unlink-during-readdir is UB on some libcs.
    var names_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&names_buf);
    var names: std.ArrayList([]u8) = .empty;
    var overflow = false;
    while (c.readdir(dir)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const owned = fba.allocator().dupe(u8, name) catch {
            overflow = true;
            break;
        };
        names.append(fba.allocator(), owned) catch {
            overflow = true;
            break;
        };
    }
    _ = c.closedir(dir);

    for (names.items) |name| {
        var fbuf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&fbuf);
        w.print("{s}/{s}", .{ dir_path, name }) catch return false;
        const full = w.buffered();
        var zf: [4096]u8 = undefined;
        const fz = pathz.pathZ(&zf, full) catch return false;
        var st: c.struct_stat = undefined;
        if (c.lstat(fz, &st) != 0) continue;
        if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
            if (!deleteTreeDir(full, progress)) return false;
        } else {
            progress.setFile(full);
            if (c.unlink(fz) != 0) return false;
            progress.done += 1;
            if (!progress.entryDone()) return false;
        }
    }
    // A directory too wide for the name buffer: re-run this level
    // until it drains (batches of ~what fits).
    if (overflow) return deleteTreeDir(dir_path, progress);
    progress.setFile(dir_path);
    if (c.rmdir(dz) != 0) return false;
    progress.done += 1;
    if (!progress.entryDone()) return false;
    return true;
}

/// Recursive size: bytes plus an entry count, walked host-side so a
/// remote "calculate folder size" never streams a listing per level.
fn runDirSize(spec: Spec) u8 {
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return emitErrno("stat");
    var bytes: u64 = 0;
    var entries: u64 = 0;
    if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
        dirSizeWalk(spec.src, &bytes, &entries, true);
    } else {
        bytes = @intCast(st.st_size);
        entries = 1;
    }
    emit(.{ .ev = "done", .done = bytes, .total = entries });
    return 0;
}

fn emitDiskUsageEvent(_: ?*anyopaque, event: disk_usage.Event) void {
    switch (event) {
        .usage => |usage| emit(.{
            .ev = "usage",
            .path = usage.path,
            .kind = @tagName(usage.kind),
            .size = usage.size,
            .allocated = usage.allocated,
            .items = usage.items,
            .errors = usage.errors,
            .skipped = usage.skipped,
            .mtime_ms = usage.mtime_ms,
        }),
        .progress => |progress| emit(.{
            .ev = "progress",
            .done = progress.done,
            .total = progress.total,
            .files_done = progress.files_done,
            .file = progress.file,
        }),
    }
}

fn runDiskUsage(allocator: std.mem.Allocator, spec: Spec) u8 {
    const result = disk_usage.scan(
        allocator,
        spec.src,
        std.mem.eql(u8, spec.pattern, "all-filesystems"),
        .{ .on_event = emitDiskUsageEvent },
    ) catch |err| return switch (err) {
        error.InvalidRoot => emitError("path must be an absolute directory"),
        error.RootNotDirectory => emitError("disk usage root is not a directory"),
        error.RootStatFailed => emitErrno("stat"),
        error.RootOpenFailed => emitErrno("open"),
        error.OutOfMemory => emitError("disk usage scanner out of memory"),
    };
    emit(.{
        .ev = "done",
        .path = spec.src,
        .kind = "dir",
        .done = result.totals.size,
        .total = result.totals.allocated,
        .size = result.totals.size,
        .allocated = result.totals.allocated,
        .items = result.totals.items,
        .errors = result.totals.errors,
        .skipped = result.totals.skipped,
        .mtime_ms = result.mtime_ms,
        .files_done = result.totals.items,
        .truncated = result.truncated,
    });
    return 0;
}

/// @param report false when the walk is a silent pre-count (delete's
/// entry total) rather than the dir_size job's own answer.
fn dirSizeWalk(dir_path: []const u8, bytes: *u64, entries: *u64, report: bool) void {
    var z: [4096]u8 = undefined;
    const dz = pathz.pathZ(&z, dir_path) catch return;
    const dir = c.opendir(dz) orelse return;
    defer _ = c.closedir(dir);
    var since_emit: u64 = 0;
    while (c.readdir(dir)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        var fbuf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&fbuf);
        w.print("{s}/{s}", .{ if (dir_path.len == 1) "" else dir_path, name }) catch continue;
        const full = w.buffered();
        var st: c.struct_stat = undefined;
        if (!statOf(full, &st, false)) continue;
        entries.* += 1;
        if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) {
            dirSizeWalk(full, bytes, entries, report);
        } else {
            bytes.* += @intCast(st.st_size);
        }
        since_emit += 1;
        if (report and since_emit >= 2000) {
            since_emit = 0;
            emit(.{ .ev = "progress", .done = bytes.*, .total = entries.* });
        }
    }
}

/// Recursive chmod/chown. Symlinks are never followed: their own
/// permissions are meaningless and following them would let a link
/// inside the tree redirect the change outside it.
fn runPermTree(spec: Spec) u8 {
    var st: c.struct_stat = undefined;
    if (!statOf(spec.src, &st, false)) return emitErrno("stat");
    var progress = Progress{};
    if (!permApply(spec, spec.src, &progress)) return emitError("could not apply to every entry");
    emit(.{ .ev = "done", .done = progress.done, .total = progress.done });
    return 0;
}

fn permApply(spec: Spec, path: []const u8, progress: *Progress) bool {
    var z: [4096]u8 = undefined;
    const pz = pathz.pathZ(&z, path) catch return false;
    var st: c.struct_stat = undefined;
    if (c.lstat(pz, &st) != 0) return false;
    const is_link = (st.st_mode & c.S_IFMT) == c.S_IFLNK;
    if (spec.uid >= 0 or spec.gid >= 0) {
        const uid: c.uid_t = if (spec.uid >= 0) @intCast(spec.uid) else @bitCast(@as(c_int, -1));
        const gid: c.gid_t = if (spec.gid >= 0) @intCast(spec.gid) else @bitCast(@as(c_int, -1));
        if (c.lchown(pz, uid, gid) != 0) return false;
    }
    if (spec.mode != 0 and !is_link) {
        if (c.chmod(pz, @intCast(spec.mode & 0o7777)) != 0) return false;
    }
    progress.done += 1;
    if (progress.done % 500 == 0)
        emit(.{ .ev = "progress", .done = progress.done, .total = @as(u64, 0) });
    if ((st.st_mode & c.S_IFMT) != c.S_IFDIR) return true;

    const dir = c.opendir(pz) orelse return false;
    var names_buf: [64 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&names_buf);
    var names: std.ArrayList([]u8) = .empty;
    var overflow_at: ?[]const u8 = null;
    while (c.readdir(dir)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        const owned = fba.allocator().dupe(u8, name) catch {
            overflow_at = name;
            break;
        };
        names.append(fba.allocator(), owned) catch {
            overflow_at = name;
            break;
        };
    }
    _ = c.closedir(dir);
    if (overflow_at != null) {
        // A directory wider than the name buffer would silently skip
        // the tail; say so rather than report a complete apply.
        emit(.{ .ev = "progress", .done = progress.done, .total = @as(u64, 0) });
        return false;
    }
    for (names.items) |name| {
        var fbuf: [4096]u8 = undefined;
        var w = std.Io.Writer.fixed(&fbuf);
        w.print("{s}/{s}", .{ if (path.len == 1) "" else path, name }) catch return false;
        if (!permApply(spec, w.buffered(), progress)) return false;
    }
    return true;
}

// ── media metadata (batched, cached, bounded) ────────────────────
//
// One request names MANY files; one reply carries one match event per
// name. Extraction always runs on the host that owns the file, so only
// the extracted key/value pairs cross the wire - never file bytes and
// never one round trip per row (the inventory's number one complaint
// about remote listings).
//
// Results are cached on the daemon host under the state dir, keyed on
// path + mtime + size, so a re-listed directory costs one fork and no
// re-parsing. Nothing is ever written into the tree being browsed.

/// Wire shape of a batch (separator, cap) is the client library's:
/// one definition, used by both ends.
const MEDIA_SEP = fsdrive.MEDIA_SEP;
const MEDIA_BATCH_MAX = fsdrive.MEDIA_BATCH_MAX;
const MEDIA_HEAD_BYTES: usize = 256 * 1024;
const MEDIA_TAIL_BYTES: usize = 128 * 1024;
/// Total bytes read across one request: a batch of very large files
/// stops early rather than turning a listing into a disk sweep.
const MEDIA_READ_BUDGET: u64 = 64 << 20;
/// Cache file caps. Drop-oldest, rewritten atomically when exceeded.
const MEDIA_CACHE_MAX_BYTES: usize = 4 << 20;
const MEDIA_CACHE_KEEP_LINES: usize = 3000;

const MediaKV = struct { k: []const u8 = "", v: []const u8 = "" };
const MediaRecord = struct {
    key: []const u8 = "",
    kind: []const u8 = "",
    meta: []MediaKV = &.{},
};

/// Where the extraction cache lives on the daemon host.
/// `SKETERM_MEDIA_CACHE_DIR` overrides it (the smokes use that to stay
/// out of the real user state dir).
fn mediaCacheDir(buf: []u8) ?[]const u8 {
    if (c.getenv("SKETERM_MEDIA_CACHE_DIR")) |p| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        if (s.len > 0) return std.fmt.bufPrint(buf, "{s}", .{s}) catch null;
    }
    if (c.getenv("XDG_STATE_HOME")) |p| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        if (s.len > 0) return std.fmt.bufPrint(buf, "{s}/sketerm/mediameta", .{s}) catch null;
    }
    if (c.getenv("HOME")) |p| {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        if (s.len > 0) return std.fmt.bufPrint(buf, "{s}/.local/state/sketerm/mediameta", .{s}) catch null;
    }
    return std.fmt.bufPrint(buf, "/tmp/sketerm-mediameta-{d}", .{c.getuid()}) catch null;
}

/// Append-only JSON-lines cache. Later records shadow earlier ones
/// (lookup scans backwards), so a re-extraction after a file change
/// needs no read-modify-write and concurrent job helpers can append
/// with a single write(2) each.
const MediaCache = struct {
    /// Stored as buffer+length, never as a slice: the struct is
    /// returned by value, and a slice into its own buffer would dangle
    /// the moment it moved.
    path_buf: [4096]u8 = undefined,
    path_len: usize = 0,
    data: []u8 = &.{},
    appended: usize = 0,

    fn path(self: *const MediaCache) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn init(allocator: std.mem.Allocator) MediaCache {
        var self = MediaCache{};
        var dir_buf: [4096]u8 = undefined;
        const dir = mediaCacheDir(&dir_buf) orelse return self;
        var path_buf: [4096]u8 = undefined;
        const p = std.fmt.bufPrint(&path_buf, "{s}/media.jsonl", .{dir}) catch return self;
        pathz.makeParentDirs(p) catch return self;
        @memcpy(self.path_buf[0..p.len], p);
        self.path_len = p.len;
        self.data = readCapped(allocator, p, MEDIA_CACHE_MAX_BYTES) orelse &.{};
        return self;
    }

    fn deinit(self: *MediaCache, allocator: std.mem.Allocator) void {
        if (self.data.len > 0) allocator.free(self.data);
    }

    /// The newest record line for `key`, or null.
    fn lookup(self: *const MediaCache, key: []const u8) ?[]const u8 {
        var needle_buf: [64]u8 = undefined;
        const needle = std.fmt.bufPrint(&needle_buf, "\"key\":\"{s}\"", .{key}) catch return null;
        var rest = self.data;
        var found: ?[]const u8 = null;
        while (rest.len > 0) {
            const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const line = rest[0..nl];
            if (std.mem.indexOf(u8, line, needle) != null) found = line;
            rest = if (nl == rest.len) rest[nl..] else rest[nl + 1 ..];
        }
        return found;
    }

    fn appendRecoverable(self: *MediaCache, line: []const u8) void {
        if (self.path_len == 0) return;
        var z: [4096]u8 = undefined;
        const p = pathz.pathZ(&z, self.path()) catch return;
        const fd = c.open(p, c.O_WRONLY | c.O_CREAT | c.O_APPEND | c.O_CLOEXEC, @as(c.mode_t, 0o600));
        if (fd < 0) return;
        // One write(2) per record: an interleaved append from another
        // job helper can then never split a line.
        // Failure only drops a cache entry; the next request re-extracts it.
        if (c.write(fd, line.ptr, line.len) != @as(isize, @intCast(line.len))) {
            _ = c.close(fd);
            return;
        }
        _ = c.close(fd);
        self.appended += 1;
    }

    /// Trim the cache back under its cap. A lost race with another
    /// helper's compaction only costs re-extraction, never correctness.
    fn finishRecoverable(self: *MediaCache, allocator: std.mem.Allocator) void {
        if (self.path_len == 0 or self.appended == 0) return;
        var z: [4096]u8 = undefined;
        const p = pathz.pathZ(&z, self.path()) catch return;
        var st: c.struct_stat = undefined;
        if (c.stat(p, &st) != 0 or st.st_size <= MEDIA_CACHE_MAX_BYTES) return;
        const all = readCapped(allocator, self.path(), 16 << 20) orelse return;
        defer allocator.free(all);
        var starts: [MEDIA_CACHE_KEEP_LINES]usize = undefined;
        var count: usize = 0;
        var oldest: usize = 0;
        var off: usize = 0;
        while (off < all.len) {
            const nl = std.mem.indexOfScalar(u8, all[off..], '\n') orelse break;
            starts[(oldest + count) % MEDIA_CACHE_KEEP_LINES] = off;
            if (count < MEDIA_CACHE_KEEP_LINES) count += 1 else oldest = (oldest + 1) % MEDIA_CACHE_KEEP_LINES;
            off += nl + 1;
        }
        var compacted: std.ArrayList(u8) = .empty;
        defer compacted.deinit(allocator);
        for (0..count) |i| {
            const start = starts[(oldest + i) % MEDIA_CACHE_KEEP_LINES];
            const nl = std.mem.indexOfScalar(u8, all[start..], '\n') orelse break;
            compacted.appendSlice(allocator, all[start .. start + nl + 1]) catch return;
        }
        atomicwrite.writeCacheFile(self.path(), compacted.items, 0o600) catch return;
    }
};

/// Read at most `cap` bytes of a line-oriented file, keeping the END
/// when it is larger (newest records shadow older ones, so the tail is
/// the half worth having) and dropping the leading partial line.
/// Null on any failure: a broken cache file must degrade to "no cache",
/// never to a failed job.
fn readCapped(allocator: std.mem.Allocator, path: []const u8, cap: usize) ?[]u8 {
    var z: [4096]u8 = undefined;
    const p = pathz.pathZ(&z, path) catch return null;
    const fd = c.open(p, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0 or st.st_size <= 0) return null;
    const size: u64 = @intCast(st.st_size);
    const want: usize = @intCast(@min(size, @as(u64, cap)));
    const buf = allocator.alloc(u8, want) catch return null;
    defer allocator.free(buf);
    const got = preadAll(fd, buf, size - want);
    if (got == 0) return null;
    // A window that starts mid-file also starts mid-record.
    const body = if (want < size)
        buf[(std.mem.indexOfScalar(u8, buf[0..got], '\n') orelse return null) + 1 .. got]
    else
        buf[0..got];
    if (body.len == 0) return null;
    // Hand back an exactly-sized allocation: the caller frees the slice
    // it holds, and a short read must not leave that length lying.
    const out = allocator.alloc(u8, body.len) catch return null;
    @memcpy(out, body);
    return out;
}

/// Reusable per-request buffers: allocated once, not once per file.
const MediaBufs = struct {
    head: []u8,
    tail: []u8,
    scratch: []u8,

    fn init(allocator: std.mem.Allocator) !MediaBufs {
        const head = try allocator.alloc(u8, MEDIA_HEAD_BYTES);
        errdefer allocator.free(head);
        const tail = try allocator.alloc(u8, MEDIA_TAIL_BYTES);
        errdefer allocator.free(tail);
        const scratch = try allocator.alloc(u8, MEDIA_HEAD_BYTES);
        return .{ .head = head, .tail = tail, .scratch = scratch };
    }

    fn deinit(self: *MediaBufs, allocator: std.mem.Allocator) void {
        allocator.free(self.head);
        allocator.free(self.tail);
        allocator.free(self.scratch);
    }
};

fn emitMediaSkip(path: []const u8, reason: []const u8) void {
    emit(.{
        .ev = "match",
        .path = path,
        .kind = "unknown",
        .cached = false,
        .text = reason,
        .meta = &[_]MediaKV{},
    });
}

fn runMediaMeta(allocator: std.mem.Allocator, spec: Spec) u8 {
    if (spec.pattern.len == 0) return emitError("media_meta needs at least one name");
    var bufs = MediaBufs.init(allocator) catch return emitError("out of memory");
    defer bufs.deinit(allocator);
    var cache = MediaCache.init(allocator);
    defer cache.deinit(allocator);

    var budget: u64 = MEDIA_READ_BUDGET;
    var done: u64 = 0;
    var truncated = false;
    var it = std.mem.splitScalar(u8, spec.pattern, MEDIA_SEP);
    while (it.next()) |name| {
        if (name.len == 0) continue;
        if (done >= MEDIA_BATCH_MAX or budget == 0) {
            truncated = true;
            break;
        }
        var path_buf: [4096]u8 = undefined;
        const full = if (name[0] == '/')
            name
        else if (std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ if (spec.src.len == 1) "" else spec.src, name })) |joined|
            joined
        else |_| {
            emitMediaSkip(name, "path too long");
            done += 1;
            continue;
        };
        mediaOne(allocator, &bufs, &cache, full, &budget);
        done += 1;
    }
    cache.finishRecoverable(allocator);
    emit(.{ .ev = "done", .done = done, .total = done, .matches = done, .truncated = truncated });
    return 0;
}

fn mediaOne(allocator: std.mem.Allocator, bufs: *MediaBufs, cache: *MediaCache, full: []const u8, budget: *u64) void {
    var z: [4096:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "{s}", .{full}) catch return emitMediaSkip(full, "path too long");
    var st: c.struct_stat = undefined;
    if (c.stat(p.ptr, &st) != 0) return emitMediaSkip(full, "cannot stat");
    if ((st.st_mode & c.S_IFMT) != c.S_IFREG) return emitMediaSkip(full, "not a regular file");
    const size: u64 = if (st.st_size > 0) @intCast(st.st_size) else 0;
    if (size == 0) return emitMediaSkip(full, "empty file");

    // Identity that changes whenever the bytes could have: a cache hit
    // on a modified file is the bug this key exists to prevent.
    const ts = if (@hasField(c.struct_stat, "st_mtim")) st.st_mtim else st.st_mtimespec;
    var hasher = Sha256.init(.{});
    hasher.update(full);
    var idbuf: [64]u8 = undefined;
    hasher.update(std.fmt.bufPrint(&idbuf, "\x00{d}.{d}\x00{d}", .{ @as(i64, ts.tv_sec), @as(i64, @intCast(ts.tv_nsec)), size }) catch return emitMediaSkip(full, "identity"));
    var digest: [Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    var key: [16]u8 = undefined;
    for (digest[0..8], 0..) |b, i| {
        _ = std.fmt.bufPrint(key[i * 2 ..][0..2], "{x:0>2}", .{b}) catch unreachable;
    }

    if (cache.lookup(&key)) |line| {
        const parsed = std.json.parseFromSlice(MediaRecord, allocator, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch null;
        if (parsed) |rec| {
            defer rec.deinit();
            emit(.{ .ev = "match", .path = full, .kind = rec.value.kind, .cached = true, .text = "", .meta = rec.value.meta });
            return;
        }
    }

    const fd = c.open(p.ptr, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return emitMediaSkip(full, "cannot open");
    defer _ = c.close(fd);
    const head_want: usize = @intCast(@min(size, @as(u64, MEDIA_HEAD_BYTES)));
    const tail_want: usize = @intCast(@min(size, @as(u64, MEDIA_TAIL_BYTES)));
    const head_n = preadAll(fd, bufs.head[0..head_want], 0);
    const tail_n = preadAll(fd, bufs.tail[0..tail_want], size - tail_want);
    budget.* -|= @as(u64, head_n) + tail_n;

    var m = mediameta.extract(.{
        .head = bufs.head[0..head_n],
        .tail = bufs.tail[0..tail_n],
        .size = size,
        .name = std.fs.path.basename(full),
        .scratch = bufs.scratch,
    });
    mediaExternal(&m, p.ptr, full);

    var kvs: [mediameta.MAX_FIELDS]MediaKV = undefined;
    for (0..m.count) |i| kvs[i] = .{ .k = m.keyAt(i), .v = m.value(i) };
    const fields = kvs[0..m.count];
    emit(.{ .ev = "match", .path = full, .kind = m.kind.name(), .cached = false, .text = "", .meta = fields });

    var line_buf: [8192]u8 = undefined;
    if (encodeEvent(&line_buf, MediaRecord{ .key = &key, .kind = m.kind.name(), .meta = fields })) |line|
        cache.appendRecoverable(line);
}

fn preadAll(fd: c_int, buf: []u8, off: u64) usize {
    var got: usize = 0;
    while (got < buf.len) {
        const n = c.pread(fd, buf.ptr + got, buf.len - got, @intCast(off + got));
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        got += @intCast(n);
    }
    return got;
}

const MEDIA_PROBE_EXTS = [_][]const u8{
    ".mp4", ".m4v",  ".mkv", ".webm", ".avi", ".mov", ".mpeg", ".mpg", ".wmv",  ".flv",
    ".ts",  ".m2ts", ".3gp", ".mp3",  ".m4a", ".aac", ".ogg",  ".oga", ".opus", ".flac",
    ".wav", ".wma",  ".ape", ".aiff", ".aif", ".mka",
};

/// Fill what the pure-Zig parsers could not from an external probe,
/// when the host actually has one. `Meta.put` is first-wins, so a
/// parsed value is never overwritten by a probed one.
fn mediaExternal(m: *mediameta.Meta, source: [*:0]const u8, name: []const u8) void {
    if (std.mem.eql(u8, m.get("media.format") orelse "", "pdf")) {
        var out: [4096]u8 = undefined;
        const n = pdfinfoText(source, &out);
        if (n > 0) applyPdfinfo(m, out[0..n]);
        return;
    }
    const wanted = switch (m.kind) {
        .video => !m.has("media.duration_ms") or !m.has("media.width"),
        .audio => !m.has("media.duration_ms"),
        .unknown => extIs(name, &MEDIA_PROBE_EXTS),
        else => false,
    };
    if (!wanted) return;
    var out: [8192]u8 = undefined;
    const n = ffprobeEntries(source, FFPROBE_META_ENTRIES, &out);
    if (n > 0) applyFfprobe(m, out[0..n]);
}

fn applyFfprobe(m: *mediameta.Meta, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (value.len == 0 or std.mem.eql(u8, value, "N/A") or std.mem.eql(u8, value, "unknown")) continue;
        if (std.mem.eql(u8, key, "duration")) {
            const secs = std.fmt.parseFloat(f64, value) catch continue;
            if (secs > 0 and secs < 30.0 * 24 * 3600) m.putInt("media.duration_ms", @intFromFloat(secs * 1000));
        } else if (std.mem.eql(u8, key, "bit_rate")) {
            const bps = std.fmt.parseInt(u64, value, 10) catch continue;
            m.putInt("media.bitrate_kbps", bps / 1000);
        } else if (std.mem.eql(u8, key, "width")) {
            mediaPutNumber(m, "media.width", value, 1 << 20);
        } else if (std.mem.eql(u8, key, "height")) {
            mediaPutNumber(m, "media.height", value, 1 << 20);
        } else if (std.mem.eql(u8, key, "sample_rate")) {
            mediaPutNumber(m, "media.sample_rate", value, 3_000_000);
        } else if (std.mem.eql(u8, key, "channels")) {
            mediaPutNumber(m, "media.channels", value, 64);
        } else if (std.mem.eql(u8, key, "codec_name")) {
            m.put("media.codec", value);
        } else if (std.mem.eql(u8, key, "codec_type")) {
            if (m.kind == .unknown) {
                if (std.mem.eql(u8, value, "video")) m.kind = .video;
                if (std.mem.eql(u8, value, "audio")) m.kind = .audio;
            }
        } else if (std.mem.startsWith(u8, key, "TAG:")) {
            applyProbeTag(m, key[4..], value);
        }
    }
    if (m.kind != .unknown) m.put("media.kind", m.kind.name());
}

fn mediaPutNumber(m: *mediameta.Meta, key: []const u8, value: []const u8, max: u64) void {
    const n = std.fmt.parseInt(u64, value, 10) catch return;
    if (n == 0 or n > max) return;
    m.putInt(key, n);
}

fn applyProbeTag(m: *mediameta.Meta, name: []const u8, value: []const u8) void {
    var lower_buf: [32]u8 = undefined;
    if (name.len > lower_buf.len) return;
    for (name, 0..) |ch, i| lower_buf[i] = std.ascii.toLower(ch);
    const lower = lower_buf[0..name.len];
    const table = [_]struct { name: []const u8, key: []const u8 }{
        .{ .name = "title", .key = "tag.title" },
        .{ .name = "artist", .key = "tag.artist" },
        .{ .name = "album", .key = "tag.album" },
        .{ .name = "album_artist", .key = "tag.album_artist" },
        .{ .name = "composer", .key = "tag.composer" },
        .{ .name = "genre", .key = "tag.genre" },
        .{ .name = "track", .key = "tag.track" },
        .{ .name = "comment", .key = "tag.comment" },
    };
    for (table) |row| {
        if (!std.mem.eql(u8, row.name, lower)) continue;
        if (std.mem.eql(u8, row.key, "tag.track")) {
            const slash = std.mem.indexOfScalar(u8, value, '/');
            m.put(row.key, if (slash) |s| value[0..s] else value);
        } else {
            m.put(row.key, value);
        }
        return;
    }
    if (std.mem.eql(u8, lower, "date") and value.len >= 4) m.put("tag.year", value[0..4]);
}

fn applyPdfinfo(m: *mediameta.Meta, text: []const u8) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const colon = std.mem.indexOfScalar(u8, raw, ':') orelse continue;
        const key = std.mem.trim(u8, raw[0..colon], " \t\r");
        const value = std.mem.trim(u8, raw[colon + 1 ..], " \t\r");
        if (value.len == 0) continue;
        if (std.mem.eql(u8, key, "Pages")) {
            mediaPutNumber(m, "doc.pages", value, 1 << 24);
        } else if (std.mem.eql(u8, key, "Title")) {
            m.put("doc.title", value);
        } else if (std.mem.eql(u8, key, "Author")) {
            m.put("doc.author", value);
        } else if (std.mem.eql(u8, key, "Producer")) {
            m.put("doc.producer", value);
        } else if (std.mem.eql(u8, key, "Page size")) {
            m.put("doc.page_size", value);
        }
    }
}

// ── tests ───────────────────────────────────────────────────────

test "nameMatches: substring default, glob with wildcards, ci" {
    const t = std.testing;
    try t.expect(nameMatches("read", "README.md"));
    try t.expect(nameMatches("ME.md", "README.md"));
    try t.expect(!nameMatches("xyz", "README.md"));
    try t.expect(nameMatches("*.md", "README.md"));
    try t.expect(nameMatches("re*me.??", "README.md"));
    try t.expect(!nameMatches("*.txt", "README.md"));
    try t.expect(nameMatches("*", "anything"));
    try t.expect(nameMatches("a?c", "AbC"));
    try t.expect(!nameMatches("a?c", "abbc"));
    try t.expect(nameMatches("*b*b*", "abxbx"));
    try t.expect(!nameMatches("*b*b*", "abxx"));
}

test "preview event carries a fully escaped 4 KiB text head" {
    var text: [4096]u8 = undefined;
    @memset(&text, 1);
    var encoded: [32 * 1024]u8 = undefined;
    const line = encodeEvent(&encoded, .{ .ev = "done", .text = &text }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(line.len > text.len);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
}

test "transportPreview serves PNG when jxl/webp cannot, refuses without any accepted codec" {
    const t = std.testing;
    var src_z: [128:0]u8 = undefined;
    const src = std.fmt.bufPrintZ(&src_z, "/tmp/.sketerm-test-tp-{d}.png", .{c.getpid()}) catch unreachable;
    var rgba: [8 * 8 * 4]u8 = undefined;
    @memset(&rgba, 0x80);
    try t.expect(c.stbi_write_png(src.ptr, 8, 8, 4, &rgba, 8 * 4) != 0);
    defer _ = c.unlink(src.ptr);
    var out_buf: [4096:0]u8 = undefined;
    // "png" as last resort: a host without libjxl/libwebp still serves.
    const out = transportPreview(t.allocator, src, "png", 512, &out_buf) orelse return error.TestUnexpectedResult;
    defer _ = c.unlink(out_buf[0..out.len :0].ptr);
    try t.expect(std.mem.endsWith(u8, out, ".png"));
    // A receiver accepting nothing usable gets a refusal, not a PNG.
    var out2: [4096:0]u8 = undefined;
    try t.expect(transportPreview(t.allocator, src, "", 512, &out2) == null);
}

test "fileHasBytes: absent and empty both read as no output" {
    const t = std.testing;
    var z: [128:0]u8 = undefined;
    const p = std.fmt.bufPrintZ(&z, "/tmp/.sketerm-test-fhb-{d}", .{c.getpid()}) catch unreachable;
    _ = c.unlink(p.ptr);
    try t.expect(!fileHasBytes(p.ptr));
    const fd = c.open(p.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC | c.O_CLOEXEC, @as(c.mode_t, 0o600));
    try t.expect(fd >= 0);
    defer _ = c.unlink(p.ptr);
    try t.expect(!fileHasBytes(p.ptr));
    try t.expect(c.write(fd, "x", 1) == 1);
    _ = c.close(fd);
    try t.expect(fileHasBytes(p.ptr));
}

test "video poster: a clip shorter than the 1s seek still yields a frame" {
    const t = std.testing;
    if (!binaryExists("ffmpeg")) return;
    var src_z: [128:0]u8 = undefined;
    const src = std.fmt.bufPrintZ(&src_z, "/tmp/.sketerm-test-poster-{d}.mp4", .{c.getpid()}) catch unreachable;
    defer _ = c.unlink(src.ptr);
    const make = [_:null]?[*:0]const u8{
        "ffmpeg", "-y",                                      "-v", "error", "-f", "lavfi",
        "-i",     "testsrc=duration=0.5:size=64x48:rate=30", src,  null,
    };
    // No lavfi/x264 on this host: nothing to assert about.
    if (!runArgv(&make) or !fileHasBytes(src.ptr)) return;
    var raw_z: [128:0]u8 = undefined;
    const raw = std.fmt.bufPrintZ(&raw_z, "/tmp/.sketerm-test-poster-{d}.png", .{c.getpid()}) catch unreachable;
    defer _ = c.unlink(raw.ptr);
    var vf_z: [64:0]u8 = undefined;
    const vf = std.fmt.bufPrintZ(&vf_z, "scale=128:128:force_original_aspect_ratio=decrease", .{}) catch unreachable;
    try t.expect(videoPosterPng(src, raw, vf));
    try t.expect(fileHasBytes(raw.ptr));
}

test "archive member validation rejects traversal and absolute paths" {
    try std.testing.expect(!unsafeArchiveMember("dir/file.txt"));
    try std.testing.expect(!unsafeArchiveMember("./dir/file.txt"));
    try std.testing.expect(unsafeArchiveMember("../escape"));
    try std.testing.expect(unsafeArchiveMember("dir/../../escape"));
    try std.testing.expect(unsafeArchiveMember("/absolute"));
}

test "CopyOpts maps the wire strings, defaulting to merge + overwrite" {
    const t = std.testing;
    const plain = CopyOpts.fromSpec(.{});
    try t.expectEqual(@as(@FieldType(CopyOpts, "conflict"), .overwrite), plain.conflict);
    try t.expect(!plain.replace);
    const skip = CopyOpts.fromSpec(.{ .conflict = "skip", .dir_mode = "merge" });
    try t.expectEqual(@as(@FieldType(CopyOpts, "conflict"), .skip), skip.conflict);
    try t.expect(!skip.replace);
    const both = CopyOpts.fromSpec(.{ .conflict = "keep_both", .dir_mode = "replace", .@"resume" = true });
    try t.expectEqual(@as(@FieldType(CopyOpts, "conflict"), .keep_both), both.conflict);
    try t.expect(both.replace and both.allow_resume);
    // An unknown policy is not an error: it falls back to what the
    // verb did before the option existed.
    try t.expectEqual(@as(@FieldType(CopyOpts, "conflict"), .overwrite), CopyOpts.fromSpec(.{ .conflict = "nonsense" }).conflict);
}

test "uniqueInDir walks past every name already on disk" {
    const t = std.testing;
    const td = pathz.TempDir.make("fsjob-uniq") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();
    var buf: [512]u8 = undefined;
    // Nothing taken yet.
    try t.expectEqualStrings("a.txt-copy", uniqueInDir(dir, "a.txt", &buf).?);
    for ([_][]const u8{ "a.txt-copy", "a.txt-copy2" }) |name| {
        var z: [4096]u8 = undefined;
        var pb: [4096]u8 = undefined;
        const p = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, name });
        const f = c.fopen(try pathz.pathZ(&z, p), "wb") orelse return error.SkipZigTest;
        _ = c.fclose(f);
    }
    try t.expectEqualStrings("a.txt-copy3", uniqueInDir(dir, "a.txt", &buf).?);
}

test "copyOneFile resumes only on matching prefix hash" {
    const t = std.testing;
    const td = pathz.TempDir.make("fsjob") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();

    var src_buf: [4096]u8 = undefined;
    var sw = std.Io.Writer.fixed(&src_buf);
    try sw.print("{s}/src.bin", .{dir});
    const src = sw.buffered();
    var dst_buf: [4096]u8 = undefined;
    var dw2 = std.Io.Writer.fixed(&dst_buf);
    try dw2.print("{s}/dst.bin", .{dir});
    const dst = dw2.buffered();
    var part_buf: [4096]u8 = undefined;
    var pw = std.Io.Writer.fixed(&part_buf);
    try pw.print("{s}/dst.bin.skpart", .{dir});
    const part = pw.buffered();

    // 1MB deterministic source.
    const data = try t.allocator.alloc(u8, 1 << 20);
    defer t.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i *% 13 +% 5);
    {
        var z: [4096]u8 = undefined;
        const f = c.fopen(try pathz.pathZ(&z, src), "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(f);
        try t.expect(c.fwrite(data.ptr, 1, data.len, f) == data.len);
    }
    // Seed a VALID partial: first 256KB.
    {
        var z: [4096]u8 = undefined;
        const f = c.fopen(try pathz.pathZ(&z, part), "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(f);
        try t.expect(c.fwrite(data.ptr, 1, 256 * 1024, f) == 256 * 1024);
    }
    var st: c.struct_stat = undefined;
    try t.expect(statOf(src, &st, true));
    // Quiet, and NOT optionally: progress lines go to fd 1, which
    // under `zig build test --listen=-` is the build runner's IPC
    // pipe. Emitting into it corrupts the protocol and wedges the
    // run -- the "test runner hangs" this file caused for a while.
    var progress = Progress{ .total = data.len, .quiet = true };
    switch (copyOneFile(src, dst, st, true, false, false, &progress)) {
        .ok => {},
        else => return error.TestUnexpectedResult,
    }
    try t.expectEqual(@as(u64, 256 * 1024), progress.resumed);
    const out_h = hashPrefix(dst, data.len, null).?;
    var expect_h: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &expect_h, .{});
    try t.expectEqualSlices(u8, &expect_h, &out_h);

    // Seed a CORRUPT partial → restart from 0.
    {
        var z: [4096]u8 = undefined;
        const f = c.fopen(try pathz.pathZ(&z, part), "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(f);
        var junk: [1024]u8 = @splat(0xAA);
        try t.expect(c.fwrite(&junk, 1, junk.len, f) == junk.len);
    }
    var progress2 = Progress{ .total = data.len, .quiet = true };
    switch (copyOneFile(src, dst, st, true, false, false, &progress2)) {
        .ok => {},
        else => return error.TestUnexpectedResult,
    }
    try t.expectEqual(@as(u64, 0), progress2.resumed);
    const out_h2 = hashPrefix(dst, data.len, null).?;
    try t.expectEqualSlices(u8, &expect_h, &out_h2);
}

test "media cache: newest record for a key wins" {
    const t = std.testing;
    var cache = MediaCache{};
    const lines =
        "{\"key\":\"aaaa\",\"kind\":\"image\",\"meta\":[{\"k\":\"media.width\",\"v\":\"1\"}]}\n" ++
        "{\"key\":\"bbbb\",\"kind\":\"audio\",\"meta\":[]}\n" ++
        "{\"key\":\"aaaa\",\"kind\":\"image\",\"meta\":[{\"k\":\"media.width\",\"v\":\"2\"}]}\n";
    const buf = try t.allocator.dupe(u8, lines);
    defer t.allocator.free(buf);
    cache.data = buf;
    const hit = cache.lookup("aaaa") orelse return error.TestUnexpectedResult;
    try t.expect(std.mem.indexOf(u8, hit, "\"v\":\"2\"") != null);
    try t.expect(cache.lookup("cccc") == null);
}

test "media cache read keeps the newest lines and drops a partial record" {
    const t = std.testing;
    const td = pathz.TempDir.make("fsjob-mm") orelse return error.SkipZigTest;
    defer td.remove();
    const dir = td.path();
    var pbuf: [4096]u8 = undefined;
    const path = try std.fmt.bufPrint(&pbuf, "{s}/lines", .{dir});
    {
        var z: [4096]u8 = undefined;
        const f = c.fopen(try pathz.pathZ(&z, path), "wb") orelse return error.SkipZigTest;
        defer _ = c.fclose(f);
        const body = "AAAAAAAAAA\nBBBBBBBBBB\nCCCCCCCCCC\n";
        try t.expect(c.fwrite(body, 1, body.len, f) == body.len);
    }
    // A 16-byte window lands mid-record; the fragment must be dropped.
    const capped = readCapped(t.allocator, path, 16) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(capped);
    try t.expectEqualStrings("CCCCCCCCCC\n", capped);
    const whole = readCapped(t.allocator, path, 4096) orelse return error.TestUnexpectedResult;
    defer t.allocator.free(whole);
    try t.expectEqualStrings("AAAAAAAAAA\nBBBBBBBBBB\nCCCCCCCCCC\n", whole);
}

test "ffprobe fallback fills only what the parsers left empty" {
    const t = std.testing;
    var m = mediameta.Meta{};
    m.kind = .video;
    m.put("media.width", "1920"); // already known: must survive
    applyFfprobe(&m,
        \\codec_type=video
        \\codec_name=h264
        \\width=640
        \\height=360
        \\duration=12.500000
        \\bit_rate=800000
        \\TAG:title=Probe Title
        \\TAG:date=2020-04-05
        \\TAG:track=3/9
        \\TAG:album=N/A
        \\
    );
    try t.expectEqualStrings("1920", m.get("media.width").?);
    try t.expectEqualStrings("360", m.get("media.height").?);
    try t.expectEqualStrings("12500", m.get("media.duration_ms").?);
    try t.expectEqualStrings("800", m.get("media.bitrate_kbps").?);
    try t.expectEqualStrings("h264", m.get("media.codec").?);
    try t.expectEqualStrings("Probe Title", m.get("tag.title").?);
    try t.expectEqualStrings("2020", m.get("tag.year").?);
    try t.expectEqualStrings("3", m.get("tag.track").?);
    // "N/A" is ffprobe for "absent", not a value.
    try t.expect(!m.has("tag.album"));
}

test "pdfinfo fallback maps the document keys" {
    const t = std.testing;
    var m = mediameta.Meta{};
    m.kind = .document;
    applyPdfinfo(&m,
        \\Title:          Handbook
        \\Author:         A. Writer
        \\Producer:       pdfTeX
        \\Pages:          42
        \\Page size:      595 x 842 pts (A4)
        \\Encrypted:      no
        \\
    );
    try t.expectEqualStrings("42", m.get("doc.pages").?);
    try t.expectEqualStrings("Handbook", m.get("doc.title").?);
    try t.expectEqualStrings("A. Writer", m.get("doc.author").?);
    try t.expectEqualStrings("pdfTeX", m.get("doc.producer").?);
    try t.expectEqualStrings("595 x 842 pts (A4)", m.get("doc.page_size").?);
}

test "cross-copy manifest totals reject overflow" {
    const t = std.testing;
    var manifest = CrossCopy.Manifest{ .allocator = t.allocator };
    defer manifest.deinit();
    try manifest.append("first", .{ .name = "first", .kind = "file", .size = std.math.maxInt(u64) });
    try t.expectError(error.Overflow, manifest.append("second", .{ .name = "second", .kind = "file", .size = 1 }));
    try t.expectEqual(std.math.maxInt(u64), manifest.total);
    try t.expectEqual(@as(u64, 1), manifest.files);
}

test "cross-copy source deletion recognizes idempotent NOENT" {
    try std.testing.expect(CrossCopy.noEntDetail("NOENT"));
    try std.testing.expect(CrossCopy.noEntDetail("delete failed: NOENT"));
    try std.testing.expect(!CrossCopy.noEntDetail("NOTEMPTY"));
}

test "cross-copy terminal errors classify permanent and transport failures" {
    durable_state.cancel_requested = false;
    durable_state.error_kind.len = 0;
    var copy = CrossCopy{
        .allocator = std.testing.allocator,
        .src = undefined,
        .dst = undefined,
        .src_host = "darkshire",
        .dst_host = "",
    };
    copy.fail("read small.txt on darkshire: permission denied", .{});
    _ = copy.emitFailure();
    try std.testing.expectEqualStrings("permanent", durable_state.error_kind.slice());

    durable_state.error_kind.len = 0;
    copy.retryable_transport = true;
    _ = copy.emitFailure();
    try std.testing.expectEqualStrings("transport", durable_state.error_kind.slice());
}

test "cleanup-only retries and deferred cancellation begin with source deletion" {
    try std.testing.expect(!needsCleanupRetry(false, true, "rename_planned"));
    try std.testing.expect(!needsCleanupRetry(true, true, "rename_planned"));
    try std.testing.expect(needsCleanupRetry(true, true, "copied"));
    try std.testing.expect(!needsCleanupRetry(true, false, "deleting"));
    try std.testing.expect(!moveDeletionStarted(true, "quarantined"));
    try std.testing.expect(moveDeletionStarted(true, "deleting"));
    try std.testing.expect(!moveDeletionStarted(false, "deleting"));
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

test "durable cancellation wins before deleting is committed" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const dir = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/jobs", .{&tmp.sub_path});
    try fsjournal.save(dir, .{
        .id = 74,
        .op = "cross_copy",
        .state = "running",
        .delete_src = true,
        .phase = "quarantined",
    });
    try t.expectEqual(fsjournal.CancelResult.requested, (try fsjournal.tryRequestCancel(t.allocator, dir, 74)).?);
    durable_state.cancel_requested = false;
    const spec = Spec{ .op = "cross_copy", .job_id = 74, .journal_dir = dir, .delete_src = true };
    const progress = Progress{ .quiet = true };
    try t.expectEqual(DeleteCommit.canceled, commitDeleting(spec, &progress, .{}));

    const path = try std.fmt.allocPrint(arena.allocator(), "{s}/74.json", .{dir});
    const parsed = try fsjournal.load(arena.allocator(), path);
    defer parsed.deinit();
    try t.expectEqualStrings("quarantined", parsed.value.phase);
    try t.expect(fsjournal.cancelRequested(dir, 74));
}

test "digest cache rejects in-place changes with restored mtime" {
    const seen = CrossCopy.HashSeen{
        .side = .src,
        .dev = 1,
        .ino = 2,
        .size = 3,
        .mtime_ns = 4,
        .ctime_ns = 5,
        .digest = [_]u8{0} ** 64,
    };
    var entry = fsdrive.Entry{
        .name = "file",
        .kind = "file",
        .dev = 1,
        .ino = 2,
        .size = 3,
        .mtime_ns = 4,
        .ctime_ns = 5,
    };
    try std.testing.expect(seen.matches(.src, entry));
    entry.ctime_ns += 1;
    try std.testing.expect(!seen.matches(.src, entry));
}

test "digest cache survives our own rename but drops foreign changes" {
    const t = std.testing;
    var list: std.ArrayList(CrossCopy.HashSeen) = .empty;
    defer list.deinit(t.allocator);
    try list.append(t.allocator, .{
        .side = .dst,
        .dev = 1,
        .ino = 2,
        .size = 3,
        .mtime_ns = 4,
        .ctime_ns = 5,
        .digest = [_]u8{0} ** 64,
    });
    // Our rename moved only ctime: the digest is restamped, not lost.
    CrossCopy.hashRestampRenamed(&list, .dst, .{
        .name = "f",
        .kind = "file",
        .dev = 1,
        .ino = 2,
        .size = 3,
        .mtime_ns = 4,
        .ctime_ns = 9,
    });
    try t.expectEqual(@as(usize, 1), list.items.len);
    try t.expectEqual(@as(i64, 9), list.items[0].ctime_ns);
    // Same inode, different size: replacement content forces a rehash.
    CrossCopy.hashRestampRenamed(&list, .dst, .{
        .name = "f",
        .kind = "file",
        .dev = 1,
        .ino = 2,
        .size = 7,
        .mtime_ns = 4,
        .ctime_ns = 11,
    });
    try t.expectEqual(@as(usize, 0), list.items.len);
}
