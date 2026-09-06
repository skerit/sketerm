//! Subprocess file jobs (copy / delete_tree / hash / find / ...) —
//! spawn, journaling, recovery, progress relay — split out of
//! daemon.zig. Functions take the owning *Daemon and are aliased back
//! into Daemon.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const wire = @import("wire.zig");
const fsjournal = @import("fsjournal.zig");
const fsjob = @import("fsjob.zig");
const pathZ = @import("../util/pathz.zig").pathZ;
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;
const Session = dmod.Session;
const FsJob = dmod.FsJob;
const FsOpReq = @import("daemon_serve.zig").FsOpReq;
const nowMs = @import("../util/clock.zig").nowMs;
const wallMs = @import("../util/clock.zig").wallMs;
const fsReplyErr = @import("daemon_serve.zig").fsReplyErr;

// ── subprocess file jobs (copy / delete_tree / hash) ────────────

/// Cap on RETAINED finished jobs (job_list history). Running jobs
/// are never dropped.
pub const MAX_FINISHED_JOBS = 64;
/// Cap on one media_meta batch's separator-joined name list.
pub const MAX_MEDIA_BATCH_BYTES = 16 * 1024;
pub const MAX_TOKEN_JOBS = 1024;
const PREVIEW_ASSET_TTL_MS: i64 = 300_000;

/// Wire verb -> job op. The wire names ARE the FsJob.Op tag names, so
/// this is the single source of truth for "is this verb a job?" --
/// daemon_serve's routing asks here rather than keeping its own list.
pub fn jobOpFor(op: []const u8) ?FsJob.Op {
    return std.meta.stringToEnum(FsJob.Op, op);
}

fn queueFsJobStartReply(self: *Daemon, cl: *Client, req: u32, job: *FsJob) void {
    job.owner = cl;
    cl.queueJson(.fs_reply, .{
        .req = req,
        .ok = true,
        .job = job.id,
        .state = @tagName(job.state),
        .done = job.done,
        .total = job.total,
        .resumed_from = job.resumed_from,
        .file = job.cur_file[0..job.cur_file_len],
        .files_done = job.files_done,
        .files_total = job.files_total,
        .message = job.message[0..job.message_len],
        .kind = job.err_kind[0..job.err_kind_len],
    });
    if (job.finished()) {
        fsJobEmit(self, job, switch (job.state) {
            .done => "done",
            .canceled => "canceled",
            else => "error",
        });
    }
}

pub fn fsStartJob(self: *Daemon, cl: *Client, r: FsOpReq) void {
    const op: FsJob.Op = jobOpFor(r.op) orelse return fsReplyErr(cl, r.req, "unknown fs job op");
    if (r.no_replace and std.mem.eql(u8, r.dir_mode, "replace"))
        return fsReplyErr(cl, r.req, "no_replace conflicts with dir_mode=replace");
    if ((op == .copy or op == .extract or op == .archive_create) and
        (r.to.len == 0 or r.to[0] != '/'))
        return fsReplyErr(cl, r.req, "to must be absolute");
    if (r.delete_destination and (op != .panelize or r.to.len == 0 or r.to[0] != '/'))
        return fsReplyErr(cl, r.req, "temporary destination must be an absolute panelize path");
    if (r.delete_destination and !std.mem.startsWith(u8, r.to, "/tmp/.sketerm-preview-"))
        return fsReplyErr(cl, r.req, "temporary destination is outside the preview scratch namespace");
    if (r.delete_source and op != .preview_transport)
        return fsReplyErr(cl, r.req, "delete_source is only valid for preview transport");
    if (op == .delete_tree and r.path.len <= 1)
        return fsReplyErr(cl, r.req, "refusing to delete /");
    if ((op == .find or op == .grep or op == .panelize or op == .live_find) and r.pattern.len == 0)
        return fsReplyErr(cl, r.req, "empty pattern");
    // media_meta carries its batch in `pattern`; the cap keeps one
    // spec line inside the job helper's stdin buffer.
    if (op == .split and r.pattern.len == 0)
        return fsReplyErr(cl, r.req, "split needs a part size");
    if (op == .media_meta) {
        if (r.pattern.len == 0) return fsReplyErr(cl, r.req, "media_meta needs at least one name");
        if (r.pattern.len > MAX_MEDIA_BATCH_BYTES) return fsReplyErr(cl, r.req, "media_meta batch too large");
    }

    // Idempotent submission closes the crash window where the job
    // started but its reply never reached the caller. Claiming the
    // existing job also resumes its event stream after reconnect.
    // A `transfer_token` match reaches further: the client rotates its
    // per-attempt client_token, and without this a retry would mint a
    // FRESH job whose randomized stage/quarantine can never adopt the
    // failed attempt's staged data (the `.sketerm-copy-47` / `-50`
    // orphan class). A failed transfer job is therefore RESTARTED from
    // its own journal under its own id.
    if (r.client_token.len > 0 or r.transfer_token.len > 0) {
        const matched: ?*FsJob = for (self.fs_jobs.items) |existing| {
            if (existing.ephemeral) continue;
            if (r.client_token.len > 0 and std.mem.eql(u8, existing.client_token, r.client_token)) break existing;
            if (r.transfer_token.len > 0 and existing.op == op and
                std.mem.eql(u8, existing.transfer_token, r.transfer_token)) break existing;
        } else null;
        if (matched) |found| {
            var existing = found;
            const same_attempt = std.mem.eql(u8, existing.client_token, r.client_token);
            if (!same_attempt and !existing.finished()) {
                // A live job for this transfer: the "failure" the client
                // retried on was its own view, not the job's. Adopt it.
                if (self.allocator.dupe(u8, r.client_token)) |fresh| {
                    self.allocator.free(existing.client_token);
                    existing.client_token = fresh;
                    journalFsJob(self, existing);
                } else |_| {}
            } else if (!same_attempt and existing.state == .failed and r.@"resume" and
                (op == .cross_copy or op == .copy))
            {
                if (r.cancel_requested and op == .cross_copy) {
                    const cancel_result = fsjournal.tryRequestRecoveryCancel(self.allocator, self.fs_job_dir, existing.id) catch {
                        cl.queueJson(.fs_reply, .{
                            .req = r.req,
                            .ok = false,
                            .@"error" = "cannot persist cancellation before transfer restart",
                            .kind = "retryable_cleanup",
                        });
                        return;
                    } orelse {
                        cl.queueJson(.fs_reply, .{
                            .req = r.req,
                            .ok = false,
                            .@"error" = "cancellation election is busy",
                            .kind = "retryable_cleanup",
                        });
                        return;
                    };
                    _ = cancel_result;
                }
                if (restartFsJobFromJournal(self, cl, existing, r.client_token)) |replacement| {
                    existing = replacement;
                } else {
                    existing.setMessage("could not restart transfer from its durable journal");
                    setFsJobErrorKind(existing, "permanent");
                    saveFsJob(self, existing) catch {
                        existing.terminal_pending = true;
                    };
                }
            }
            if (r.cancel_requested and !existing.finished() and
                !fsjournal.cancelRequested(self.fs_job_dir, existing.id))
            {
                const cancel_result = fsjournal.tryRequestCancel(self.allocator, self.fs_job_dir, existing.id) catch {
                    cl.queueJson(.fs_reply, .{
                        .req = r.req,
                        .ok = false,
                        .@"error" = "cannot persist cancellation while adopting transfer",
                        .kind = "retryable_cleanup",
                    });
                    return;
                };
                if (cancel_result) |settled| {
                    applyDurableCancelResult(self, existing, settled);
                } else {
                    if (existing.cancel_election_pending) {
                        cl.queueJson(.fs_reply, .{
                            .req = r.req,
                            .ok = false,
                            .@"error" = "transfer cancellation election is already pending",
                            .kind = "retryable_cleanup",
                        });
                        return;
                    }
                    existing.cancel_election_pending = true;
                    existing.cancel_client = cl;
                    existing.cancel_req = r.req;
                    existing.cancel_reply_start = true;
                    return;
                }
            }
            if (existing.terminal_pending) {
                saveFsJob(self, existing) catch return fsReplyErr(cl, r.req, "cannot persist terminal job state");
                existing.terminal_pending = false;
            }
            queueFsJobStartReply(self, cl, r.req, existing);
            return;
        }
    }
    if (r.cancel_requested)
        return fsReplyErr(cl, r.req, "canceled transfer has no durable coordinator job to recover");
    var source_owner: ?*FsJob = null;
    if (r.delete_source) {
        for (self.fs_jobs.items) |existing| {
            if (existing.owner == cl and existing.owns_dst and existing.state == .done and
                std.mem.eql(u8, existing.dst, r.path))
            {
                source_owner = existing;
                break;
            }
        }
        if (source_owner == null)
            return fsReplyErr(cl, r.req, "preview source is not a completed asset owned by this client");
    }
    if (self.next_fs_job_id == std.math.maxInt(u64))
        return fsReplyErr(cl, r.req, "filesystem job identity namespace is exhausted");
    const job = spawnFsJob(self, cl, op, self.next_fs_job_id, .{
        .src = r.path,
        .dst = r.to,
        .pattern = r.pattern,
        .src_host = r.src_host,
        .dst_host = r.dst_host,
        .client_token = r.client_token,
        .transfer_token = r.transfer_token,
        .resumable = r.@"resume",
        .within_ms = r.within_ms,
        .start_ms = r.start_ms,
        .max_matches = r.max_matches,
        .perm = .{ .mode = r.mode, .uid = if (r.uid) |v| @as(i64, v) else -1, .gid = if (r.gid) |v| @as(i64, v) else -1 },
        .copy = .{ .conflict = r.conflict, .dir_mode = r.dir_mode, .no_replace = r.no_replace },
        .image_codecs = r.image_codecs,
        .wire_cache = r.wire_cache,
        .owns_dst = op == .panelize and r.delete_destination,
        .owns_src = op == .preview_transport and r.delete_source,
        .delete_src = op == .cross_copy and r.delete_src,
        .dial_tries = r.dial_tries,
        .verify = r.verify,
    }) catch
        return fsReplyErr(cl, r.req, "cannot start job");
    if (source_owner) |producer| {
        producer.owns_dst = false;
        producer.cleanup_at_ms = nowMs();
    }
    self.next_fs_job_id = job.id +| 1;
    cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true, .job = job.id });
}

/// Respawn a terminally-failed transfer job from its journal, keeping
/// its id — and therefore its staged partials, destination stage,
/// quarantine and durable move phase. The new attempt's client_token
/// replaces the spent one. Returns null when the journal is gone or
/// the respawn fails; the caller then replays the terminal state.
fn restartFsJobFromJournal(self: *Daemon, cl: *Client, existing: *FsJob, client_token: []const u8) ?*FsJob {
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{d}.json", .{ self.fs_job_dir, existing.id }) catch return null;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const parsed = fsjournal.load(arena.allocator(), path) catch return null;
    defer parsed.deinit();
    const rec = parsed.value;
    const op = fsOpFromName(rec.op) orelse return null;
    const replacement = spawnFsJob(self, cl, op, rec.id, .{
        .src = rec.src,
        .dst = rec.dst,
        .pattern = rec.pattern,
        .src_host = rec.src_host,
        .dst_host = rec.dst_host,
        .client_token = client_token,
        .transfer_token = rec.transfer_token,
        .resumable = true,
        .copy = .{ .conflict = rec.conflict, .no_replace = rec.no_replace },
        .delete_src = rec.delete_src,
        .verify = rec.verify,
        .phase = rec.phase,
        .source_quarantine = rec.source_quarantine,
        .destination_stage = rec.destination_stage,
        .source_fingerprint = rec.source_fingerprint,
        .source_kind = rec.source_kind,
        .source_dev = rec.source_dev,
        .source_ino = rec.source_ino,
        .recovery_attempts = rec.recovery_attempts,
        .done = rec.done,
        .total = rec.total,
        .resumed_from = rec.resumed_from,
        .files_done = rec.files_done,
        .files_total = rec.files_total,
        .preserve_journal_on_failure = true,
    }) catch return null;
    // spawnFsJob appends; replace the spent job's slot so its id stays
    // singular in the list and in job_list.
    for (self.fs_jobs.items, 0..) |j, i| {
        if (j != existing) continue;
        self.fs_jobs.items[i] = replacement;
        _ = self.fs_jobs.pop();
        existing.deinit(false);
        break;
    }
    return replacement;
}

/// Short-lived client-owned probes: no journal, no history, killed
/// with the requesting client. They report a view's decoration, not
/// a mutation worth recovering.
pub fn ephemeralOp(op: FsJob.Op) bool {
    return FsJob.producesAsset(op) or op == .dir_size or op == .media_meta or op == .git_status or op == .diff or op == .git_diff or op == .disk_usage;
}

/// Recursive-permission arguments; -1 keeps the current owner or
/// group, mode 0 keeps the current mode.
pub const PermArgs = struct { mode: u32 = 0, uid: i64 = -1, gid: i64 = -1 };

/// Copy-collision arguments, forwarded verbatim to the helper.
pub const CopyArgs = struct { conflict: []const u8 = "", dir_mode: []const u8 = "", no_replace: bool = false };

/// Everything a job run needs beyond its op and id. One struct so
/// call sites name what they set and default the rest.
pub const FsJobArgs = struct {
    src: []const u8 = "",
    dst: []const u8 = "",
    pattern: []const u8 = "",
    src_host: []const u8 = "",
    dst_host: []const u8 = "",
    client_token: []const u8 = "",
    transfer_token: []const u8 = "",
    resumable: bool = false,
    within_ms: u64 = 0,
    start_ms: u64 = 0,
    max_matches: u64 = 0,
    perm: PermArgs = .{},
    copy: CopyArgs = .{},
    image_codecs: []const u8 = "",
    wire_cache: bool = false,
    owns_dst: bool = false,
    owns_src: bool = false,
    /// cross_copy move semantics: journaled, so a daemon-restart
    /// respawn still deletes the source instead of degrading to a copy.
    delete_src: bool = false,
    verify: bool = false,
    phase: []const u8 = "",
    source_quarantine: []const u8 = "",
    destination_stage: []const u8 = "",
    source_fingerprint: []const u8 = "",
    source_kind: []const u8 = "",
    source_dev: u64 = 0,
    source_ino: u64 = 0,
    recovery_attempts: u32 = 0,
    initial_message: []const u8 = "",
    initial_error_kind: []const u8 = "",
    done: u64 = 0,
    total: u64 = 0,
    resumed_from: u64 = 0,
    files_done: u64 = 0,
    files_total: u64 = 0,
    /// NOT journaled: a respawn dials with the full budget.
    dial_tries: u32 = 0,
    /// Recovery reuses an existing job ID whose record may be the only
    /// path to quarantined source data; spawn failure must retain it.
    preserve_journal_on_failure: bool = false,
};

pub fn spawnFsJob(self: *Daemon, owner: ?*Client, op: FsJob.Op, id: u64, args: FsJobArgs) !*FsJob {
    const src = args.src;
    const dst = args.dst;
    const pattern = args.pattern;
    const src_host = args.src_host;
    const dst_host = args.dst_host;
    const client_token = args.client_token;
    const resumable = args.resumable;
    const within_ms = args.within_ms;
    const max_matches = args.max_matches;
    const perm = args.perm;
    const copy = args.copy;
    const image_codecs = args.image_codecs;
    const ephemeral = ephemeralOp(op) or args.owns_dst or args.owns_src;
    var exe_buf: [4096:0]u8 = undefined;
    const exe = @import("../util/platform.zig").selfExecPathZ(&exe_buf) orelse return error.NoExecutable;
    var spec_aw: std.Io.Writer.Allocating = .init(self.allocator);
    defer spec_aw.deinit();
    try std.json.Stringify.value(.{
        .op = @tagName(op),
        .src = src,
        .dst = dst,
        .pattern = pattern,
        .src_host = src_host,
        .dst_host = dst_host,
        .@"resume" = resumable,
        .job_id = id,
        .journal_dir = if (ephemeral) "" else self.fs_job_dir,
        .within_ms = within_ms,
        .start_ms = args.start_ms,
        .max_matches = max_matches,
        .client_token = client_token,
        .transfer_token = args.transfer_token,
        .mode = perm.mode,
        .uid = perm.uid,
        .gid = perm.gid,
        .conflict = copy.conflict,
        .dir_mode = copy.dir_mode,
        .no_replace = copy.no_replace,
        .image_codecs = image_codecs,
        .wire_cache = args.wire_cache,
        .delete_source = args.owns_src,
        .delete_src = args.delete_src,
        .verify = args.verify,
        .phase = args.phase,
        .source_quarantine = args.source_quarantine,
        .destination_stage = args.destination_stage,
        .source_fingerprint = args.source_fingerprint,
        .source_kind = args.source_kind,
        .source_dev = args.source_dev,
        .source_ino = args.source_ino,
        .recovery_attempts = args.recovery_attempts,
        .done = args.done,
        .total = args.total,
        .resumed_from = args.resumed_from,
        .files_done = args.files_done,
        .files_total = args.files_total,
        .dial_tries = args.dial_tries,
    }, .{}, &spec_aw.writer);
    try spec_aw.writer.writeByte('\n');

    // Allocate every daemon-owned record before forking. The child
    // remains blocked on the spec pipe until its durable record is
    // installed below.
    var job_initialized = false;
    const src_owned = try self.allocator.dupe(u8, src);
    errdefer if (!job_initialized) self.allocator.free(src_owned);
    const dst_owned = try self.allocator.dupe(u8, dst);
    errdefer if (!job_initialized) self.allocator.free(dst_owned);
    const pattern_owned = try self.allocator.dupe(u8, pattern);
    errdefer if (!job_initialized) self.allocator.free(pattern_owned);
    const src_host_owned = try self.allocator.dupe(u8, src_host);
    errdefer if (!job_initialized) self.allocator.free(src_host_owned);
    const dst_host_owned = try self.allocator.dupe(u8, dst_host);
    errdefer if (!job_initialized) self.allocator.free(dst_host_owned);
    const client_token_owned = try self.allocator.dupe(u8, client_token);
    errdefer if (!job_initialized) self.allocator.free(client_token_owned);
    const transfer_token_owned = try self.allocator.dupe(u8, args.transfer_token);
    errdefer if (!job_initialized) self.allocator.free(transfer_token_owned);
    const conflict_owned = try self.allocator.dupe(u8, copy.conflict);
    errdefer if (!job_initialized) self.allocator.free(conflict_owned);
    const job = try self.allocator.create(FsJob);
    errdefer if (!job_initialized) self.allocator.destroy(job);

    var spec_pipe: [2]c_int = undefined;
    var out_pipe: [2]c_int = undefined;
    if (c.pipe(&spec_pipe) != 0) return error.PipeFailed;
    errdefer {
        _ = c.close(spec_pipe[0]);
        _ = c.close(spec_pipe[1]);
    }
    if (c.pipe(&out_pipe) != 0) return error.PipeFailed;
    errdefer {
        _ = c.close(out_pipe[0]);
        _ = c.close(out_pipe[1]);
    }
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.setpgid(0, 0);
        _ = c.dup2(spec_pipe[0], 0);
        _ = c.dup2(out_pipe[1], 1);
        for ([_]c_int{ spec_pipe[0], spec_pipe[1], out_pipe[0], out_pipe[1] }) |fd| _ = c.close(fd);
        const argv = [_:null]?[*:0]const u8{ exe, "--job", null };
        _ = c.execv(exe, @ptrCast(@constCast(&argv)));
        c._exit(127);
    }
    _ = c.setpgid(pid, pid);
    _ = c.close(spec_pipe[0]);
    spec_pipe[0] = -1;
    _ = c.close(out_pipe[1]);
    out_pipe[1] = -1;
    const fl = c.fcntl(out_pipe[0], c.F_GETFL);
    _ = c.fcntl(out_pipe[0], c.F_SETFL, fl | c.O_NONBLOCK);
    _ = c.fcntl(out_pipe[0], c.F_SETFD, c.FD_CLOEXEC);
    job.* = .{
        .allocator = self.allocator,
        .id = id,
        .op = op,
        .owner = owner,
        .pid = pid,
        .out_fd = out_pipe[0],
        .src = src_owned,
        .dst = dst_owned,
        .pattern = pattern_owned,
        .src_host = src_host_owned,
        .dst_host = dst_host_owned,
        .client_token = client_token_owned,
        .transfer_token = transfer_token_owned,
        .conflict = conflict_owned,
        .no_replace = copy.no_replace,
        .resumable = resumable,
        .ephemeral = ephemeral,
        .owns_dst = args.owns_dst,
        .owns_src = args.owns_src,
        .delete_src = args.delete_src,
        .verify = args.verify,
        .done = args.done,
        .total = args.total,
        .resumed_from = args.resumed_from,
        .files_done = args.files_done,
        .files_total = args.files_total,
        .recovery_attempts = args.recovery_attempts,
        .cancel_pending = !ephemeral and fsjournal.cancelRequested(self.fs_job_dir, id),
    };
    job.setPhase(args.phase);
    job.setMessage(args.initial_message);
    setFsJobErrorKind(job, args.initial_error_kind);
    job_initialized = true;
    // The job owns the read end from here on; its deinit closes it,
    // so the pipe errdefer must not close it a second time.
    out_pipe[0] = -1;
    var job_owned = true;
    errdefer if (job_owned) job.deinit(true);
    self.fs_jobs.append(self.allocator, job) catch return error.OutOfMemory;
    saveFsJob(self, job) catch {
        _ = self.fs_jobs.pop();
        if (!args.preserve_journal_on_failure) deleteFsJobJournal(self, id);
        return error.JournalFailed;
    };
    const sw = spec_aw.written();
    var off: usize = 0;
    while (off < sw.len) {
        const n = c.write(spec_pipe[1], sw.ptr + off, sw.len - off);
        if (n < 0 and std.posix.errno(n) == .INTR) continue;
        if (n <= 0) break;
        off += @intCast(n);
    }
    _ = c.close(spec_pipe[1]);
    spec_pipe[1] = -1;
    if (off != sw.len) {
        _ = self.fs_jobs.pop();
        if (!args.preserve_journal_on_failure) deleteFsJobJournal(self, id);
        return error.SpecWriteFailed;
    }
    job_owned = false;
    return job;
}

pub fn fsOpFromName(name: []const u8) ?FsJob.Op {
    inline for (std.meta.fields(FsJob.Op)) |field| {
        if (std.mem.eql(u8, name, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn moveHelperOwnsJournal(job: *const FsJob) bool {
    if (job.op != .cross_copy or (!job.delete_src and !job.no_replace) or job.pid <= 0) return false;
    if (job.out_fd >= 0) return true;
    return !job.finished() and c.kill(job.pid, 0) == 0;
}

/// Whether `kill(-job.pid, …)` addresses this job's helper GROUP.
///
/// `job.pid` is not always a live child: a journal record restored at
/// startup defaults to -1 and a detached helper is reset to -1, and
/// `kill(-pid)` reads those as process-group selectors — `-0` is the
/// DAEMON'S OWN group (a self-inflicted SIGSTOP that freezes every
/// session on the host) and `-(-1)` is pid 1. Every other signalling
/// site in this file already guards on `pid > 0`; this is that guard
/// with a name.
fn liveJobGroup(job: *const FsJob) bool {
    return job.pid > 0;
}

fn cancelNeedsDurableFence(op: FsJob.Op, delete_src: bool, no_replace: bool) bool {
    return op == .cross_copy and (delete_src or no_replace);
}

pub fn journalFsJob(self: *Daemon, job: *FsJob) void {
    // A cross-move helper owns its journal after the initial record is
    // installed and until stdout closes. Two independent load/merge/save
    // writers can each be atomic yet still overwrite the stronger phase.
    if (moveHelperOwnsJournal(job)) return;
    saveFsJob(self, job) catch {};
}

pub fn saveFsJob(self: *Daemon, job: *FsJob) !void {
    if (self.fs_job_dir.len == 0 or job.ephemeral) return;
    // The helper writes copy/delete phase boundaries directly so they
    // survive a daemon crash. A progress event already queued in its
    // pipe must not race afterwards and overwrite that stronger proof.
    var quarantine_buf: [4096]u8 = undefined;
    var quarantine_len: usize = 0;
    var destination_stage_buf: [4096]u8 = undefined;
    var destination_stage_len: usize = 0;
    var fingerprint_buf: [64]u8 = undefined;
    var fingerprint_len: usize = 0;
    var source_kind_buf: [16]u8 = undefined;
    var source_kind_len: usize = 0;
    var source_dev: u64 = 0;
    var source_ino: u64 = 0;
    var path_buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&path_buf, "{s}/{d}.json", .{ self.fs_job_dir, job.id })) |path| {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        if (fsjournal.load(arena.allocator(), path)) |parsed_value| {
            var parsed = parsed_value;
            defer parsed.deinit();
            job.done = @max(job.done, parsed.value.done);
            job.total = @max(job.total, parsed.value.total);
            job.resumed_from = @max(job.resumed_from, parsed.value.resumed_from);
            job.files_done = @max(job.files_done, parsed.value.files_done);
            job.files_total = @max(job.files_total, parsed.value.files_total);
            if (fsjournal.phaseRank(parsed.value.phase) > fsjournal.phaseRank(job.phase[0..job.phase_len]))
                job.setPhase(parsed.value.phase);
            quarantine_len = @min(parsed.value.source_quarantine.len, quarantine_buf.len);
            @memcpy(quarantine_buf[0..quarantine_len], parsed.value.source_quarantine[0..quarantine_len]);
            destination_stage_len = @min(parsed.value.destination_stage.len, destination_stage_buf.len);
            @memcpy(destination_stage_buf[0..destination_stage_len], parsed.value.destination_stage[0..destination_stage_len]);
            fingerprint_len = @min(parsed.value.source_fingerprint.len, fingerprint_buf.len);
            @memcpy(fingerprint_buf[0..fingerprint_len], parsed.value.source_fingerprint[0..fingerprint_len]);
            source_kind_len = @min(parsed.value.source_kind.len, source_kind_buf.len);
            @memcpy(source_kind_buf[0..source_kind_len], parsed.value.source_kind[0..source_kind_len]);
            source_dev = parsed.value.source_dev;
            source_ino = parsed.value.source_ino;
        } else |_| {}
    } else |_| {}
    try fsjournal.save(self.fs_job_dir, .{
        .id = job.id,
        .op = @tagName(job.op),
        .state = @tagName(job.state),
        .src = job.src,
        .dst = job.dst,
        .pattern = job.pattern,
        .src_host = job.src_host,
        .dst_host = job.dst_host,
        .@"resume" = job.resumable,
        .conflict = job.conflict,
        .no_replace = job.no_replace,
        .delete_src = job.delete_src,
        .verify = job.verify,
        .phase = job.phase[0..job.phase_len],
        .source_quarantine = quarantine_buf[0..quarantine_len],
        .destination_stage = destination_stage_buf[0..destination_stage_len],
        .source_fingerprint = fingerprint_buf[0..fingerprint_len],
        .source_kind = source_kind_buf[0..source_kind_len],
        .source_dev = source_dev,
        .source_ino = source_ino,
        .recovery_attempts = job.recovery_attempts,
        .pid = job.pid,
        .done = job.done,
        .total = job.total,
        .resumed_from = job.resumed_from,
        .files_done = job.files_done,
        .files_total = job.files_total,
        .message = job.message[0..job.message_len],
        .error_kind = job.err_kind[0..job.err_kind_len],
        .client_token = job.client_token,
        .transfer_token = job.transfer_token,
        .acknowledged = job.acknowledged,
    });
}

pub fn deleteFsJobJournal(self: *Daemon, id: u64) void {
    const guard = fsjournal.lockControl(self.fs_job_dir, id) catch return;
    var path_buf: [4096:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{d}.json", .{ self.fs_job_dir, id }) catch {
        guard.release();
        return;
    };
    if (!fsjournal.clearCancel(self.fs_job_dir, id)) {
        guard.release();
        return;
    }
    _ = c.unlink(path.ptr);
    guard.release();
    fsjournal.clearControl(self.fs_job_dir, id);
}

fn applyDurableCancelResult(self: *Daemon, job: *FsJob, result: fsjournal.CancelResult) void {
    switch (result) {
        .requested => {
            job.cancel_pending = true;
            job.state = .running;
            job.setMessage("canceling safely");
            fsJobEmit(self, job, "progress");
        },
        .delete_committed => {
            job.cancel_pending = false;
            job.setMessage("source deletion already committed; finishing cleanup");
            fsJobEmit(self, job, "progress");
        },
        .finished => {},
    }
}

fn finishCancelElection(self: *Daemon, job: *FsJob, result: fsjournal.CancelResult) void {
    applyDurableCancelResult(self, job, result);
    if (job.cancel_client) |cl| if (!cl.dead and job.cancel_req != 0) {
        if (job.cancel_reply_start)
            queueFsJobStartReply(self, cl, job.cancel_req, job)
        else
            cl.queueJson(.fs_reply, .{ .req = job.cancel_req, .ok = true });
    };
    job.cancel_client = null;
    job.cancel_req = 0;
    job.cancel_reply_start = false;
    job.cancel_election_pending = false;
}

/// Retry helper-held cancellation elections without blocking the poll loop.
pub fn pumpFsJobCancelElections(self: *Daemon) void {
    for (self.fs_jobs.items) |job| {
        if (!job.cancel_election_pending) continue;
        const result = fsjournal.tryRequestCancel(self.allocator, self.fs_job_dir, job.id) catch {
            if (job.cancel_client) |cl| if (!cl.dead and job.cancel_req != 0) {
                if (job.cancel_reply_start)
                    cl.queueJson(.fs_reply, .{
                        .req = job.cancel_req,
                        .ok = false,
                        .@"error" = "cannot persist cancellation while adopting transfer",
                        .kind = "retryable_cleanup",
                    })
                else
                    fsReplyErr(cl, job.cancel_req, "cannot persist transfer cancellation");
            };
            job.cancel_client = null;
            job.cancel_req = 0;
            job.cancel_reply_start = false;
            job.cancel_election_pending = false;
            continue;
        } orelse continue;
        finishCancelElection(self, job, result);
    }
}

fn setFsJobErrorKind(job: *FsJob, kind: []const u8) void {
    job.err_kind_len = @min(kind.len, job.err_kind.len);
    @memcpy(job.err_kind[0..job.err_kind_len], kind[0..job.err_kind_len]);
}

/// The eight journal strings a restored job owns.
///
/// Split out of `restoredFsJob` so the partial-build rollback is an
/// `errdefer` in a function that actually returns an error. Inlined into
/// the `?*FsJob` original, every one of those errdefers was dead: an OOM
/// on the fourth dupe leaked the first three, in the daemon, on every
/// journal restore.
const RestoredStrings = struct {
    src: []u8,
    dst: []u8,
    pattern: []u8,
    src_host: []u8,
    dst_host: []u8,
    client_token: []u8,
    transfer_token: []u8,
    conflict: []u8,

    fn free(self: RestoredStrings, allocator: std.mem.Allocator) void {
        allocator.free(self.src);
        allocator.free(self.dst);
        allocator.free(self.pattern);
        allocator.free(self.src_host);
        allocator.free(self.dst_host);
        allocator.free(self.client_token);
        allocator.free(self.transfer_token);
        allocator.free(self.conflict);
    }
};

fn dupeRestoredStrings(allocator: std.mem.Allocator, rec: fsjournal.Record) !RestoredStrings {
    const src = try allocator.dupe(u8, rec.src);
    errdefer allocator.free(src);
    const dst = try allocator.dupe(u8, rec.dst);
    errdefer allocator.free(dst);
    const pattern = try allocator.dupe(u8, rec.pattern);
    errdefer allocator.free(pattern);
    const src_host = try allocator.dupe(u8, rec.src_host);
    errdefer allocator.free(src_host);
    const dst_host = try allocator.dupe(u8, rec.dst_host);
    errdefer allocator.free(dst_host);
    const client_token = try allocator.dupe(u8, rec.client_token);
    errdefer allocator.free(client_token);
    const transfer_token = try allocator.dupe(u8, rec.transfer_token);
    errdefer allocator.free(transfer_token);
    const conflict = try allocator.dupe(u8, rec.conflict);
    return .{
        .src = src,
        .dst = dst,
        .pattern = pattern,
        .src_host = src_host,
        .dst_host = dst_host,
        .client_token = client_token,
        .transfer_token = transfer_token,
        .conflict = conflict,
    };
}

pub fn restoredFsJob(self: *Daemon, rec: fsjournal.Record, op: FsJob.Op, state: FsJob.State) ?*FsJob {
    // Restore degrades to "this job is not adopted" on OOM; the journal
    // record stays on disk for the next restore attempt. Both bail-outs
    // below therefore clean up explicitly -- this function cannot return
    // an error, so an errdefer here would never run.
    const strings = dupeRestoredStrings(self.allocator, rec) catch return null;
    const job = self.allocator.create(FsJob) catch {
        strings.free(self.allocator);
        return null;
    };
    job.* = .{
        .allocator = self.allocator,
        .id = rec.id,
        .op = op,
        .owner = null,
        .pid = @intCast(rec.pid),
        .out_fd = -1,
        .state = state,
        .done = rec.done,
        .total = rec.total,
        .resumed_from = rec.resumed_from,
        .files_done = rec.files_done,
        .files_total = rec.files_total,
        .src = strings.src,
        .dst = strings.dst,
        .pattern = strings.pattern,
        .src_host = strings.src_host,
        .dst_host = strings.dst_host,
        .client_token = strings.client_token,
        .transfer_token = strings.transfer_token,
        .conflict = strings.conflict,
        .no_replace = rec.no_replace,
        .acknowledged = rec.acknowledged,
        .resumable = rec.@"resume",
        .delete_src = rec.delete_src,
        .verify = rec.verify,
        .recovery_attempts = rec.recovery_attempts,
        .cancel_pending = fsjournal.cancelRequested(self.fs_job_dir, rec.id),
    };
    job.setMessage(rec.message);
    setFsJobErrorKind(job, rec.error_kind);
    job.setPhase(rec.phase);
    self.fs_jobs.append(self.allocator, job) catch {
        job.deinit(false);
        return null;
    };
    return job;
}

fn phaseNeedsSafetyRecovery(rec: fsjournal.Record) bool {
    if (!rec.delete_src or !std.mem.eql(u8, rec.op, "cross_copy")) return false;
    const phase = fsjournal.phaseRank(rec.phase);
    return phase >= fsjournal.phaseRank("copied") and phase < fsjournal.phaseRank("source_deleted");
}

fn needsSafetyRecovery(fs_job_dir: []const u8, rec: fsjournal.Record) bool {
    if (!std.mem.eql(u8, rec.op, "cross_copy")) return false;
    if (rec.delete_src) return fsjournal.cancelRequested(fs_job_dir, rec.id) or phaseNeedsSafetyRecovery(rec);
    return rec.no_replace and fsjournal.cancelRequested(fs_job_dir, rec.id);
}

fn journalIdFromName(name: []const u8) ?u64 {
    if (!std.mem.endsWith(u8, name, ".json")) return null;
    return std.fmt.parseInt(u64, name[0 .. name.len - ".json".len], 10) catch null;
}

/// Reconstruct stable job IDs. Interrupted local copies respawn with
/// verified resume; helpers still alive after a daemon crash remain
/// controllable by PID and publish their terminal state to the journal.
pub fn restoreFsJobs(self: *Daemon) void {
    if (self.fs_jobs_restored or self.fs_job_dir.len == 0) return;
    self.fs_jobs_restored = true;
    var z: [4096]u8 = undefined;
    const dz = pathZ(&z, self.fs_job_dir) catch return;
    const dir = c.opendir(dz) orelse return;
    defer _ = c.closedir(dir);
    while (c.readdir(dir)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        const filename_id = journalIdFromName(name) orelse continue;
        // An unsupported record is still authoritative for its id. Reusing
        // that number would overwrite its only staging/quarantine ledger.
        self.next_fs_job_id = @max(self.next_fs_job_id, filename_id +| 1);
        var pbuf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ self.fs_job_dir, name }) catch continue;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const parsed = fsjournal.load(arena_state.allocator(), path) catch continue;
        defer parsed.deinit();
        const rec = parsed.value;
        const op = fsOpFromName(rec.op) orelse continue;
        self.next_fs_job_id = @max(self.next_fs_job_id, rec.id +| 1);
        const state: FsJob.State = if (std.mem.eql(u8, rec.state, "done"))
            .done
        else if (std.mem.eql(u8, rec.state, "failed"))
            .failed
        else if (std.mem.eql(u8, rec.state, "canceled"))
            .canceled
        else if (std.mem.eql(u8, rec.state, "paused"))
            .paused
        else
            .running;
        if (state == .done or state == .canceled) {
            _ = fsjournal.clearCancel(self.fs_job_dir, rec.id);
            _ = restoredFsJob(self, rec, op, state);
            continue;
        }
        const safety_recovery = needsSafetyRecovery(self.fs_job_dir, rec);
        if (state == .failed and !safety_recovery) {
            _ = restoredFsJob(self, rec, op, state);
            continue;
        }
        if (rec.pid > 0 and c.kill(@intCast(rec.pid), 0) == 0) {
            _ = restoredFsJob(self, rec, op, if (safety_recovery) .running else state);
            continue;
        }
        if (op == .copy or op == .cross_copy or op == .live_find) {
            const cleanup_recovery = safety_recovery;
            if (op != .live_find and !cleanup_recovery) {
                const job = restoredFsJob(self, rec, op, .failed) orelse continue;
                job.setMessage("transfer helper was interrupted; waiting for the durable retry policy");
                setFsJobErrorKind(job, "transport");
                saveFsJob(self, job) catch {
                    job.terminal_pending = true;
                };
                continue;
            }
            if (cleanup_recovery and rec.recovery_attempts >= 3) {
                const job = restoredFsJob(self, rec, op, .failed) orelse continue;
                job.setMessage("source cleanup repeatedly crashed; quarantine retained");
                setFsJobErrorKind(job, "permanent");
                saveFsJob(self, job) catch {
                    job.terminal_pending = true;
                };
                continue;
            }
            // dir_mode is deliberately absent: the destination was
            // already replaced before any bytes moved, so a
            // restart merges into the partial result instead of
            // destroying it.
            _ = spawnFsJob(self, null, op, rec.id, .{
                .src = rec.src,
                .dst = rec.dst,
                .pattern = rec.pattern,
                .src_host = rec.src_host,
                .dst_host = rec.dst_host,
                .client_token = rec.client_token,
                .transfer_token = rec.transfer_token,
                .resumable = true,
                .copy = .{ .conflict = rec.conflict, .no_replace = rec.no_replace },
                .delete_src = rec.delete_src,
                .verify = rec.verify,
                .phase = rec.phase,
                .source_quarantine = rec.source_quarantine,
                .destination_stage = rec.destination_stage,
                .source_fingerprint = rec.source_fingerprint,
                .source_kind = rec.source_kind,
                .source_dev = rec.source_dev,
                .source_ino = rec.source_ino,
                .recovery_attempts = rec.recovery_attempts + @intFromBool(cleanup_recovery),
                .done = rec.done,
                .total = rec.total,
                .resumed_from = rec.resumed_from,
                .files_done = rec.files_done,
                .files_total = rec.files_total,
                .initial_message = rec.message,
                .initial_error_kind = rec.error_kind,
                .preserve_journal_on_failure = true,
            }) catch {
                const job = restoredFsJob(self, rec, op, .failed) orelse continue;
                job.setMessage("could not resume after daemon restart");
                saveFsJob(self, job) catch {
                    job.terminal_pending = true;
                };
            };
        } else {
            const job = restoredFsJob(self, rec, op, .failed) orelse continue;
            job.setMessage("operation interrupted by daemon restart");
            saveFsJob(self, job) catch {
                job.terminal_pending = true;
            };
        }
    }
}

pub fn refreshDetachedFsJobs(self: *Daemon) void {
    for (self.fs_jobs.items) |job| {
        if (job.restart_pending or job.out_fd >= 0 or job.pid <= 0) continue;
        if (job.finished()) {
            if (job.state == .canceled and c.kill(job.pid, 0) != 0) {
                job.pid = -1;
                saveFsJob(self, job) catch {
                    job.terminal_pending = true;
                };
            }
            continue;
        }
        if (c.kill(job.pid, 0) == 0) continue;
        var pbuf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{d}.json", .{ self.fs_job_dir, job.id }) catch continue;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const parsed = fsjournal.load(arena_state.allocator(), path) catch {
            job.state = .failed;
            job.setMessage("detached helper exited without a final journal record");
            saveFsJob(self, job) catch {
                job.terminal_pending = true;
                continue;
            };
            fsJobEmit(self, job, "error");
            continue;
        };
        defer parsed.deinit();
        const state = parsed.value.state;
        job.pid = -1;
        job.done = @max(job.done, parsed.value.done);
        job.total = @max(job.total, parsed.value.total);
        job.resumed_from = @max(job.resumed_from, parsed.value.resumed_from);
        job.files_done = @max(job.files_done, parsed.value.files_done);
        job.files_total = @max(job.files_total, parsed.value.files_total);
        if (fsjournal.phaseRank(parsed.value.phase) > fsjournal.phaseRank(job.phase[0..job.phase_len]))
            job.setPhase(parsed.value.phase);
        setFsJobErrorKind(job, parsed.value.error_kind);
        if (std.mem.eql(u8, state, "done")) {
            job.state = .done;
            job.cancel_pending = false;
            job.setMessage(parsed.value.message);
            _ = fsjournal.clearCancel(self.fs_job_dir, job.id);
            fsJobEmit(self, job, "done");
        } else if (std.mem.eql(u8, state, "canceled")) {
            job.state = .canceled;
            job.cancel_pending = false;
            job.setMessage(parsed.value.message);
            _ = fsjournal.clearCancel(self.fs_job_dir, job.id);
            fsJobEmit(self, job, "canceled");
        } else if (needsSafetyRecovery(self.fs_job_dir, parsed.value)) {
            job.pid = -1;
            job.restart_pending = true;
        } else if (std.mem.eql(u8, state, "failed")) {
            // The detached helper reached a structured terminal result.
            // Preserve its kind: only an unexplained disappearance is a
            // transport failure eligible for automatic retry.
            job.state = .failed;
            job.setMessage(parsed.value.message);
            fsJobEmit(self, job, "error");
        } else {
            job.state = .failed;
            if (job.op == .copy or job.op == .cross_copy) {
                job.setMessage("transfer helper was interrupted; waiting for the durable retry policy");
                setFsJobErrorKind(job, "transport");
                saveFsJob(self, job) catch {
                    job.terminal_pending = true;
                    continue;
                };
            } else job.setMessage(parsed.value.message);
            fsJobEmit(self, job, "error");
        }
    }
}

/// Replace helpers that died after the durable copy boundary. The
/// quarantine journal makes this safe: recovery never deletes `src`.
pub fn restartCrashedFsJobs(self: *Daemon) void {
    var i: usize = 0;
    while (i < self.fs_jobs.items.len) : (i += 1) {
        const old = self.fs_jobs.items[i];
        if (!old.restart_pending) continue;
        var path_buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{d}.json", .{ self.fs_job_dir, old.id }) catch {
            old.restart_pending = false;
            old.state = .failed;
            old.setMessage("cannot locate durable move recovery record");
            old.terminal_pending = true;
            continue;
        };
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const parsed = fsjournal.load(arena.allocator(), path) catch {
            old.restart_pending = false;
            old.state = .failed;
            old.setMessage("cannot load durable move recovery record");
            old.terminal_pending = true;
            continue;
        };
        defer parsed.deinit();
        const rec = parsed.value;
        if (rec.recovery_attempts >= 3) {
            old.restart_pending = false;
            old.state = .failed;
            old.setMessage("source cleanup repeatedly crashed; quarantine retained");
            setFsJobErrorKind(old, "permanent");
            old.terminal_pending = true;
            continue;
        }
        const replacement = spawnFsJob(self, old.owner, .cross_copy, rec.id, .{
            .src = rec.src,
            .dst = rec.dst,
            .pattern = rec.pattern,
            .src_host = rec.src_host,
            .dst_host = rec.dst_host,
            .client_token = rec.client_token,
            .transfer_token = rec.transfer_token,
            .resumable = true,
            .copy = .{ .conflict = rec.conflict, .no_replace = rec.no_replace },
            .delete_src = rec.delete_src,
            .verify = rec.verify,
            .phase = rec.phase,
            .source_quarantine = rec.source_quarantine,
            .destination_stage = rec.destination_stage,
            .source_fingerprint = rec.source_fingerprint,
            .source_kind = rec.source_kind,
            .source_dev = rec.source_dev,
            .source_ino = rec.source_ino,
            .recovery_attempts = rec.recovery_attempts + 1,
            .done = rec.done,
            .total = rec.total,
            .resumed_from = rec.resumed_from,
            .files_done = rec.files_done,
            .files_total = rec.files_total,
            .initial_message = rec.message,
            .initial_error_kind = rec.error_kind,
            .preserve_journal_on_failure = true,
        }) catch {
            old.restart_pending = false;
            old.state = .failed;
            old.setMessage("could not resume source cleanup after helper crash");
            setFsJobErrorKind(old, "permanent");
            old.terminal_pending = true;
            continue;
        };
        // spawnFsJob appends. Replace the old slot so job IDs and
        // client ownership remain singular and poll sees the new fd.
        self.fs_jobs.items[i] = replacement;
        _ = self.fs_jobs.pop();
        old.deinit(false);
    }
}

/// job_cancel / job_pause / job_resume / job_list. Any client may
/// control any job — the daemon is per-user; a reconnecting
/// browser must be able to manage jobs its dead predecessor
/// started.
pub fn fsJobOp(self: *Daemon, cl: *Client, r: FsOpReq) void {
    if (std.mem.eql(u8, r.op, "job_list")) {
        const Row = struct {
            job: u64,
            op: []const u8,
            state: []const u8,
            done: u64,
            total: u64,
            src: []const u8,
            dst: []const u8,
            src_host: []const u8,
            dst_host: []const u8,
            client_token: []const u8,
            message: []const u8,
            kind: []const u8,
        };
        var rows: std.ArrayList(Row) = .empty;
        defer rows.deinit(self.allocator);
        for (self.fs_jobs.items) |j| {
            if (j.ephemeral) continue;
            rows.append(self.allocator, .{
                .job = j.id,
                .op = @tagName(j.op),
                .state = @tagName(j.state),
                .done = j.done,
                .total = j.total,
                .src = j.src,
                .dst = j.dst,
                .src_host = j.src_host,
                .dst_host = j.dst_host,
                .client_token = j.client_token,
                .message = j.message[0..j.message_len],
                .kind = j.err_kind[0..j.err_kind_len],
            }) catch break;
        }
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true, .jobs = rows.items });
        return;
    }
    const job = for (self.fs_jobs.items) |j| {
        if (j.id == r.job) break j;
    } else return fsReplyErr(cl, r.req, "no such job");

    if (std.mem.eql(u8, r.op, "job_ack")) {
        if (!job.finished()) return fsReplyErr(cl, r.req, "job is not finished");
        if (job.out_fd >= 0) {
            if (job.ack_req != 0 and job.owner != null and !job.owner.?.dead)
                return fsReplyErr(cl, r.req, "job acknowledgment already pending");
            job.owner = cl;
            job.ack_req = r.req;
            return;
        }
        job.acknowledged = true;
        saveFsJob(self, job) catch {
            job.acknowledged = false;
            return fsReplyErr(cl, r.req, "cannot persist job acknowledgment");
        };
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "job_cancel")) {
        if (!job.finished()) {
            const durable_cancel = cancelNeedsDurableFence(job.op, job.delete_src, job.no_replace);
            if (durable_cancel) {
                // A previously paused helper may have stopped while
                // committing its journal. Resume it before waiting for
                // the cancellation/delete election lock.
                if (job.pid > 0) _ = c.kill(-job.pid, c.SIGCONT);
                if (job.cancel_election_pending)
                    return fsReplyErr(cl, r.req, "job cancellation election is already pending");
                const result = fsjournal.tryRequestCancel(self.allocator, self.fs_job_dir, job.id) catch
                    return fsReplyErr(cl, r.req, "cannot persist transfer cancellation");
                if (result) |settled| {
                    applyDurableCancelResult(self, job, settled);
                    cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
                } else {
                    job.cancel_election_pending = true;
                    job.cancel_client = cl;
                    job.cancel_req = r.req;
                }
                return;
            }
            // SIGCONT first: a SIGSTOPped child never dispatches
            // SIGKILL... actually SIGKILL cannot be blocked even
            // stopped, but the CONT keeps wait semantics simple.
            if (job.pid > 0) {
                _ = c.kill(-job.pid, c.SIGCONT);
                _ = c.kill(-job.pid, c.SIGKILL);
            }
            job.state = .canceled;
            saveFsJob(self, job) catch {
                job.terminal_pending = true;
                return fsReplyErr(cl, r.req, "cannot persist canceled job state");
            };
            fsJobEmit(self, job, "canceled");
        }
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "job_pause")) {
        if (job.finished()) return fsReplyErr(cl, r.req, "job already finished");
        if (job.cancel_pending) return fsReplyErr(cl, r.req, "job cancellation is pending");
        if (!liveJobGroup(job)) return fsReplyErr(cl, r.req, "job has no running helper");
        _ = c.kill(-job.pid, c.SIGSTOP);
        job.state = .paused;
        journalFsJob(self, job);
        fsJobEmit(self, job, "paused");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "job_resume")) {
        if (job.finished()) return fsReplyErr(cl, r.req, "job already finished");
        if (!liveJobGroup(job)) return fsReplyErr(cl, r.req, "job has no running helper");
        _ = c.kill(-job.pid, c.SIGCONT);
        job.state = .running;
        journalFsJob(self, job);
        fsJobEmit(self, job, "resumed");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else {
        fsReplyErr(cl, r.req, "unknown job op");
    }
}

/// Spool-lead thresholds (bytes the encoder may be ahead of the reader).
/// A `pub var` so the smoke rig can shrink them to something a short
/// clip reaches; at the defaults a CRF-28 1280-wide preview holds one
/// to two minutes of lead before the encoder is stopped.
pub const SpoolLead = struct { stop: u64, cont: u64 };
pub var spool_lead: SpoolLead = .{ .stop = 12 << 20, .cont = 4 << 20 };

pub const SpoolSignal = enum { stop, cont };

/// Whether the encoder should be stopped or continued given how far
/// the spool is ahead of the reader. Hysteresis: stop past `stop`,
/// continue only once the reader has caught up to within `cont`.
pub fn spoolThrottleStep(written: u64, read_pos: u64, throttled: bool, lead: SpoolLead) ?SpoolSignal {
    const ahead = written -| read_pos;
    if (!throttled and ahead > lead.stop) return .stop;
    if (throttled and ahead < lead.cont) return .cont;
    return null;
}

/// Throttle a preview_stream encoder behind its reader: it is pointless
/// to burn the host's CPU encoding two hours of film for a viewer that
/// is thirty seconds in (or paused). The helper's progress events carry
/// the spool size (`job.done`), `spoolNoteRead` the reader's position;
/// the group is SIGSTOPped past the lead and SIGCONTed once the reader
/// closes in. A stopped helper emits no progress, so the only wake-up
/// is a read -- and a client that stops reading leaves it idle, which
/// is the point. Client death still kills a stopped group (SIGKILL).
pub fn spoolThrottle(job: *FsJob) void {
    if (job.pid <= 0) return;
    if (job.finished()) return spoolRelease(job);
    if (job.state == .paused) return;
    const signal = spoolThrottleStep(job.done, job.spool_read_pos, job.throttled, spool_lead) orelse return;
    switch (signal) {
        .stop => _ = c.kill(-job.pid, c.SIGSTOP),
        .cont => _ = c.kill(-job.pid, c.SIGCONT),
    }
    job.throttled = signal == .stop;
}

/// Let a throttled group run, unconditionally.
fn spoolRelease(job: *FsJob) void {
    if (!job.throttled or job.pid <= 0) return;
    _ = c.kill(-job.pid, c.SIGCONT);
    job.throttled = false;
}

/// A client read `[.., end)` of a file under the spool prefix: if it is
/// a live preview spool, advance its reader position and reconsider
/// the throttle.
pub fn spoolNoteRead(self: *Daemon, path: []const u8, end: u64) void {
    for (self.fs_jobs.items) |job| {
        if (job.op != .preview_stream or job.finished()) continue;
        if (!std.mem.eql(u8, job.done_path[0..job.done_path_len], path)) continue;
        if (end > job.spool_read_pos) job.spool_read_pos = end;
        spoolThrottle(job);
        return;
    }
}

test "spoolThrottleStep: stop past the lead, continue once caught up, hysteresis between" {
    const t = std.testing;
    const lead: SpoolLead = .{ .stop = 100, .cont = 40 };
    try t.expectEqual(@as(?SpoolSignal, null), spoolThrottleStep(50, 0, false, lead));
    try t.expectEqual(@as(?SpoolSignal, .stop), spoolThrottleStep(101, 0, false, lead));
    // Inside the band nothing changes in either state.
    try t.expectEqual(@as(?SpoolSignal, null), spoolThrottleStep(101, 30, true, lead));
    try t.expectEqual(@as(?SpoolSignal, null), spoolThrottleStep(150, 100, false, lead));
    try t.expectEqual(@as(?SpoolSignal, .cont), spoolThrottleStep(150, 120, true, lead));
    // A reader ahead of the writer (impossible, but a saturating sub) continues.
    try t.expectEqual(@as(?SpoolSignal, .cont), spoolThrottleStep(10, 50, true, lead));
}

/// When a job's scratch asset may go: now if nobody owns it, after the
/// TTL for a one-shot preview, and for a playback spool only once its
/// owner disconnects (the client-death sweep turns a positive stamp
/// into "now"), since the viewer keeps reading it long after the
/// encode finished.
fn armAssetCleanup(job: *FsJob) void {
    job.cleanup_at_ms = if (job.owner == null or job.owner.?.dead)
        nowMs()
    else if (job.op == .preview_stream)
        std.math.maxInt(i64)
    else
        nowMs() + PREVIEW_ASSET_TTL_MS;
}

/// Push one fs_job event toward the owner (if still alive).
pub fn fsJobEmit(self: *Daemon, job: *FsJob, ev: []const u8) void {
    _ = self;
    const owner = job.owner orelse return;
    if (owner.dead) return;
    if (job.op == .disk_usage and std.mem.eql(u8, ev, "done")) {
        owner.queueJson(.fs_job, .{
            .job = job.id,
            .ev = ev,
            .state = @tagName(job.state),
            .path = job.done_path[0..job.done_path_len],
            .kind = "dir",
            .done = job.done,
            .total = job.total,
            .size = job.done,
            .allocated = job.total,
            .items = job.usage_items,
            .errors = job.usage_errors,
            .skipped = job.usage_skipped,
            .mtime_ms = job.usage_mtime_ms,
            .files_done = job.usage_items,
            .truncated = job.truncated,
        });
        return;
    }
    owner.queueJson(.fs_job, .{
        .job = job.id,
        .ev = ev,
        .state = @tagName(job.state),
        .done = job.done,
        .total = job.total,
        .resumed_from = job.resumed_from,
        .hash = if (job.has_hash) job.hash_hex[0..] else "",
        .message = job.message[0..job.message_len],
        .matches = job.matches,
        .truncated = job.truncated,
        .rejected = job.rejected,
        .exit_status = job.exit_status,
        .duration_ms = job.duration_ms,
        .encoder = job.encoder[0..job.encoder_len],
        .path = job.done_path[0..job.done_path_len],
        .keep = job.done_kept,
        .kind = job.err_kind[0..job.err_kind_len],
        .text = job.done_text[0..job.done_text_len],
        .file = job.cur_file[0..job.cur_file_len],
        .files_done = job.files_done,
        .files_total = job.files_total,
    });
}

/// Drain a job helper's progress pipe; a read of 0 = helper exit.
pub fn fsJobReadable(self: *Daemon, job: *FsJob) void {
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.read(job.out_fd, &buf, buf.len);
        if (n < 0) return; // EAGAIN — more next tick
        if (n == 0) return fsJobExited(self, job);
        job.lbuf.appendSlice(self.allocator, buf[0..@intCast(n)]) catch return;
        while (std.mem.indexOfScalar(u8, job.lbuf.items, '\n')) |nl| {
            fsJobLine(self, job, job.lbuf.items[0..nl]);
            const rest = job.lbuf.items.len - (nl + 1);
            std.mem.copyForwards(u8, job.lbuf.items[0..rest], job.lbuf.items[nl + 1 ..]);
            job.lbuf.shrinkRetainingCapacity(rest);
        }
    }
}

/// One extracted media-metadata field, forwarded verbatim.
pub const MetaKV = struct { k: []const u8 = "", v: []const u8 = "" };

pub fn fsJobLine(self: *Daemon, job: *FsJob, line: []const u8) void {
    const Ev = struct {
        ev: []const u8 = "",
        done: u64 = 0,
        total: u64 = 0,
        resumed_from: u64 = 0,
        hash: []const u8 = "",
        message: []const u8 = "",
        path: []const u8 = "",
        line: u64 = 0,
        text: []const u8 = "",
        kind: []const u8 = "",
        size: u64 = 0,
        allocated: u64 = 0,
        items: u64 = 0,
        errors: u64 = 0,
        skipped: u64 = 0,
        mtime_ms: i64 = 0,
        matches: u64 = 0,
        truncated: bool = false,
        /// Live-query status detail (ev == "ready").
        watches: u64 = 0,
        watch_limit: bool = false,
        /// panelize: output lines that were not usable paths, and
        /// what the command exited with (-1 = killed by a signal).
        rejected: u64 = 0,
        exit_status: i64 = 0,
        duration_ms: u64 = 0,
        /// preview_stream: the encoder in use ("x264" / "vaapi").
        encoder: []const u8 = "",
        /// Progress detail: the entry in flight (present only when
        /// it CHANGED — the helper does not repeat it) and the
        /// entry counters for tree operations.
        file: []const u8 = "",
        files_done: u64 = 0,
        files_total: u64 = 0,
        phase: []const u8 = "",
        /// media_meta: extracted key/value pairs for one file, plus
        /// whether the helper served them from its cache.
        meta: []const MetaKV = &.{},
        cached: bool = false,
        /// done: the result path is a PERSISTENT host-side cache
        /// file, not a temp asset — nobody may unlink it.
        keep: bool = false,
        /// git_status match detail: the two porcelain-v2 columns and
        /// a rename/copy source. Absent on every other verb.
        xy: []const u8 = "",
        orig: []const u8 = "",
        /// git_status `repo` event: the branch header, and whether
        /// the browsed root is a repository at all.
        repo: bool = false,
        /// git_diff `repo` event: git knows the file. Its `initial`
        /// means "the repository has no HEAD commit yet", and no
        /// other field of this event applies to git_diff.
        tracked: bool = false,
        branch: []const u8 = "",
        upstream: []const u8 = "",
        ahead: i64 = 0,
        behind: i64 = 0,
        have_ab: bool = false,
        detached: bool = false,
        initial: bool = false,
        root: bool = false,
    };
    const parsed = std.json.parseFromSlice(Ev, self.allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();
    const e = parsed.value;
    if (std.mem.eql(u8, e.ev, "usage")) {
        if (job.owner) |owner| {
            if (!owner.dead) owner.queueJson(.fs_job, .{
                .job = job.id,
                .ev = e.ev,
                .path = e.path,
                .kind = e.kind,
                .size = e.size,
                .allocated = e.allocated,
                .items = e.items,
                .errors = e.errors,
                .skipped = e.skipped,
                .mtime_ms = e.mtime_ms,
            });
        }
        return;
    }
    if (std.mem.eql(u8, e.ev, "asset")) {
        job.done_path_len = @min(e.path.len, job.done_path.len);
        @memcpy(job.done_path[0..job.done_path_len], e.path[0..job.done_path_len]);
        armAssetCleanup(job);
        return;
    }
    if (std.mem.eql(u8, e.ev, "repo")) {
        // git_status' repository header. Its own field set, so the
        // per-record events below stay as small as they were.
        if (job.owner) |owner| {
            if (!owner.dead) owner.queueJson(.fs_job, .{
                .job = job.id,
                .ev = e.ev,
                .repo = e.repo,
                .tracked = e.tracked,
                .branch = e.branch,
                .upstream = e.upstream,
                .text = e.text,
                .ahead = e.ahead,
                .behind = e.behind,
                .have_ab = e.have_ab,
                .detached = e.detached,
                .initial = e.initial,
                .root = e.root,
                .truncated = e.truncated,
            });
        }
        return;
    }
    if (std.mem.eql(u8, e.ev, "match") or std.mem.eql(u8, e.ev, "unmatch") or
        std.mem.eql(u8, e.ev, "resync") or std.mem.eql(u8, e.ev, "ready") or
        std.mem.eql(u8, e.ev, "reject") or std.mem.eql(u8, e.ev, "line"))
    {
        // Streaming query events: forwarded verbatim toward the
        // owner (never stored -- the stream IS the result). `ready`
        // is a live query's status line and repeats whenever one of
        // its bounds is newly hit; `reject` is one output line a
        // panelize command produced that was not a usable path;
        // `line` is one diff line (the diff viewer's whole payload —
        // swallowing it here left the verb silently empty).
        if (std.mem.eql(u8, e.ev, "match")) job.matches += 1;
        if (job.owner) |owner| {
            if (!owner.dead) owner.queueJson(.fs_job, .{
                .job = job.id,
                .ev = e.ev,
                .path = e.path,
                .line = e.line,
                .text = e.text,
                .kind = e.kind,
                .size = e.size,
                .mtime_ms = e.mtime_ms,
                .meta = e.meta,
                .cached = e.cached,
                .matches = e.matches,
                .truncated = e.truncated,
                .watches = e.watches,
                .watch_limit = e.watch_limit,
                .xy = e.xy,
                .orig = e.orig,
            });
        }
        return;
    }
    // Error/phase events may omit counters. Never let their JSON
    // defaults erase progress that is already durable in the daemon.
    if (e.done > job.done) job.done = e.done;
    if (e.total > job.total) job.total = e.total;
    // Sticky, on EVERY event kind: the helper repeats neither the
    // in-flight path nor a zero resume offset, so a running row
    // must keep what it last learned (before this, "resumed from
    // N" could only ever appear once the job had already ended).
    if (e.file.len > 0) {
        job.cur_file_len = @min(e.file.len, job.cur_file.len);
        @memcpy(job.cur_file[0..job.cur_file_len], e.file[0..job.cur_file_len]);
    }
    if (e.resumed_from > 0) job.resumed_from = e.resumed_from;
    if (e.duration_ms > 0) job.duration_ms = e.duration_ms;
    if (e.encoder.len > 0) {
        job.encoder_len = @min(e.encoder.len, job.encoder.len);
        @memcpy(job.encoder[0..job.encoder_len], e.encoder[0..job.encoder_len]);
    }
    if (job.op == .preview_stream) {
        // Any line that is not progress (done, error) ends the encode: a
        // group stopped between its last progress line and its exit
        // would otherwise never close its stdout, and the job would sit
        // finished-but-unreaped with its spool on disk forever.
        if (std.mem.eql(u8, e.ev, "progress")) spoolThrottle(job) else spoolRelease(job);
    }
    if (e.files_done > job.files_done) job.files_done = e.files_done;
    if (e.files_total > job.files_total) job.files_total = e.files_total;
    if (fsjournal.phaseRank(e.phase) > fsjournal.phaseRank(job.phase[0..job.phase_len])) job.setPhase(e.phase);
    if (std.mem.eql(u8, e.ev, "done")) {
        if (job.op == .disk_usage) {
            job.done = e.size;
            job.total = e.allocated;
            job.files_done = e.items;
            job.usage_items = e.items;
            job.usage_errors = e.errors;
            job.usage_skipped = e.skipped;
            job.usage_mtime_ms = e.mtime_ms;
        }
        job.matches = if (e.matches > 0) e.matches else job.matches;
        job.truncated = e.truncated;
        job.rejected = e.rejected;
        job.exit_status = e.exit_status;
        // Cancel raced completion: the work DID finish — honesty
        // says report done, not canceled.
        job.state = .done;
        job.cancel_pending = false;
        if (e.hash.len == 64) {
            @memcpy(&job.hash_hex, e.hash[0..64]);
            job.has_hash = true;
        }
        job.done_path_len = @min(e.path.len, job.done_path.len);
        @memcpy(job.done_path[0..job.done_path_len], e.path[0..job.done_path_len]);
        job.done_kept = e.keep;
        job.done_text_len = @min(e.text.len, job.done_text.len);
        @memcpy(job.done_text[0..job.done_text_len], e.text[0..job.done_text_len]);
        if (job.owns_dst or job.owns_src or FsJob.producesAsset(job.op)) armAssetCleanup(job);
        if (!moveHelperOwnsJournal(job)) {
            saveFsJob(self, job) catch {
                job.terminal_pending = true;
                return;
            };
        }
        fsJobEmit(self, job, "done");
    } else if (std.mem.eql(u8, e.ev, "canceled")) {
        job.state = .canceled;
        job.cancel_pending = false;
        job.setMessage(e.message);
        fsJobEmit(self, job, "canceled");
    } else if (std.mem.eql(u8, e.ev, "error")) {
        job.setMessage(e.message);
        setFsJobErrorKind(job, e.kind);
        if (cancelNeedsDurableFence(job.op, job.delete_src, job.no_replace) and
            std.mem.eql(u8, e.kind, "retryable_cleanup"))
        {
            // The helper's final journal record remains running. EOF
            // replaces it with a bounded recovery helper; no terminal
            // failure is visible unless that recovery budget expires.
            job.state = .running;
            fsJobEmit(self, job, "progress");
            return;
        }
        job.state = .failed;
        if (!moveHelperOwnsJournal(job)) {
            saveFsJob(self, job) catch {
                job.terminal_pending = true;
                return;
            };
        }
        fsJobEmit(self, job, "error");
    } else {
        // A running job may report WHY it is not moving (a cross-host
        // copy reconnecting to a host that dropped). Sticky like the
        // in-flight path, so the panel shows the reason for the stall
        // instead of a row that silently stops advancing.
        if (e.message.len > 0) job.setMessage(e.message);
        fsJobEmit(self, job, "progress");
        journalFsJob(self, job);
    }
}

/// Helper stdout hit EOF: reap the child and finalize state. A
/// helper that died without a done/error line (crash, SIGKILL)
/// maps to failed — unless cancel already claimed it.
pub fn fsJobExited(self: *Daemon, job: *FsJob) void {
    var st: c_int = 0;
    _ = c.waitpid(job.pid, &st, 0);
    const journal_failed = c.WIFEXITED(st) and c.WEXITSTATUS(st) == fsjob.JOURNAL_EXIT_CODE;
    job.releaseOwnedSource();
    _ = c.close(job.out_fd);
    job.out_fd = -1;
    var emit_terminal = job.terminal_pending;
    if (!job.finished()) {
        if (cancelNeedsDurableFence(job.op, job.delete_src, job.no_replace)) {
            var path_buf: [4096]u8 = undefined;
            if (std.fmt.bufPrint(&path_buf, "{s}/{d}.json", .{ self.fs_job_dir, job.id })) |path| {
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                if (fsjournal.load(arena.allocator(), path)) |parsed_value| {
                    var parsed = parsed_value;
                    defer parsed.deinit();
                    job.done = @max(job.done, parsed.value.done);
                    job.total = @max(job.total, parsed.value.total);
                    job.resumed_from = @max(job.resumed_from, parsed.value.resumed_from);
                    job.files_done = @max(job.files_done, parsed.value.files_done);
                    job.files_total = @max(job.files_total, parsed.value.files_total);
                    job.setPhase(parsed.value.phase);
                    job.setMessage(parsed.value.message);
                    setFsJobErrorKind(job, parsed.value.error_kind);
                    if (std.mem.eql(u8, parsed.value.state, "done") or
                        std.mem.eql(u8, parsed.value.state, "canceled"))
                    {
                        job.state = if (std.mem.eql(u8, parsed.value.state, "done"))
                            .done
                        else
                            .canceled;
                        job.cancel_pending = false;
                        emit_terminal = true;
                    } else if (needsSafetyRecovery(self.fs_job_dir, parsed.value)) {
                        job.pid = -1;
                        job.restart_pending = true;
                        return;
                    } else if (std.mem.eql(u8, parsed.value.state, "failed")) {
                        job.state = .failed;
                        emit_terminal = true;
                    }
                } else |_| {}
            } else |_| {}
        }
        if (!job.finished()) {
            job.state = .failed;
            if (journal_failed) {
                job.setMessage("transfer helper could not persist its terminal journal state");
                setFsJobErrorKind(job, "permanent");
            } else if (job.op == .copy or job.op == .cross_copy) {
                job.setMessage("transfer helper was interrupted; waiting for the durable retry policy");
                setFsJobErrorKind(job, "transport");
            } else {
                job.setMessage("job helper died");
                setFsJobErrorKind(job, "permanent");
            }
            emit_terminal = true;
        }
    }
    // The helper writes its detached-recovery record just before
    // exiting. Reassert daemon-owned progress/acknowledgment only
    // after EOF, so the helper can never overwrite a confirmed ack.
    if (job.ack_req != 0) job.acknowledged = true;
    saveFsJob(self, job) catch {
        if (job.ack_req != 0) job.acknowledged = false;
        job.terminal_pending = emit_terminal;
        return;
    };
    if (emit_terminal) {
        job.terminal_pending = false;
        fsJobEmit(self, job, switch (job.state) {
            .done => "done",
            .canceled => "canceled",
            else => "error",
        });
    }
    if (job.ack_req != 0) {
        if (job.owner) |owner| if (!owner.dead)
            owner.queueJson(.fs_reply, .{ .req = job.ack_req, .ok = true });
        job.ack_req = 0;
    }
    // Retention trim happens in reap() — this runs mid-iteration
    // over fs_jobs and must not reshape the list.
}

test "detached terminal records restore their structured error kind" {
    var none = [_]u8{};
    var job = FsJob{
        .allocator = std.testing.allocator,
        .id = 1,
        .op = .cross_copy,
        .owner = null,
        .pid = -1,
        .out_fd = -1,
        .src = &none,
        .dst = &none,
        .pattern = &none,
        .src_host = &none,
        .dst_host = &none,
        .client_token = &none,
        .transfer_token = &none,
        .conflict = &none,
    };
    setFsJobErrorKind(&job, "transport");
    try std.testing.expectEqualStrings("transport", job.err_kind[0..job.err_kind_len]);
}

test "a restore that runs out of memory duplicates no string it cannot free" {
    const t = std.testing;
    // Every one of these eight dupes used to be guarded by an errdefer
    // in a `?*FsJob` function, so none of them ever ran: an OOM on the
    // fourth dupe leaked the first three, inside the daemon, on journal
    // restore. Sweep every allocation and fail it -- testing.allocator
    // reports any survivor.
    const rec = fsjournal.Record{
        .id = 7,
        .op = "cross_copy",
        .src = "/src/path",
        .dst = "/dst/path",
        .pattern = "*.txt",
        .src_host = "alpha",
        .dst_host = "beta",
        .conflict = "skip",
        .client_token = "client-token",
        .transfer_token = "transfer-token",
    };

    var counting = t.FailingAllocator.init(t.allocator, .{});
    const ok = try dupeRestoredStrings(counting.allocator(), rec);
    ok.free(t.allocator);
    const allocations = counting.alloc_index;
    try t.expectEqual(@as(usize, 8), allocations);

    for (0..allocations) |index| {
        var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = index });
        try t.expectError(error.OutOfMemory, dupeRestoredStrings(failing.allocator(), rec));
    }
}

test "pause and resume refuse a job whose helper pid is not a group" {
    const t = std.testing;
    const a = t.allocator;
    var empty: [0]u8 = .{};
    var d = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..] };
    defer d.fs_jobs.deinit(a);
    var cl = Client{ .allocator = a, .fd = -1, .id = 1 };
    defer cl.rbuf.deinit(a);
    defer cl.wbuf.deinit(a);
    defer cl.audio_wbuf.deinit(a);

    var none = [_]u8{};
    var job = FsJob{
        .allocator = a,
        .id = 3,
        .op = .copy,
        .owner = null,
        .pid = 0,
        .out_fd = -1,
        .state = .running,
        .src = &none,
        .dst = &none,
        .pattern = &none,
        .src_host = &none,
        .dst_host = &none,
        .client_token = &none,
        .transfer_token = &none,
        .conflict = &none,
    };
    try d.fs_jobs.append(a, &job);

    // 0 is the daemon's OWN process group and -1 negates to pid 1:
    // signalling either is a self-inflicted freeze, not a paused helper.
    for ([_]c.pid_t{ 0, -1 }) |pid| {
        for ([_][]const u8{ "job_pause", "job_resume" }) |op| {
            job.pid = pid;
            job.state = .running;
            cl.wbuf.clearRetainingCapacity();
            fsJobOp(&d, &cl, .{ .req = 5, .op = op, .job = job.id });
            const peeled = (try wire.peelFrame(cl.wbuf.items)) orelse return error.TestUnexpectedResult;
            try t.expectEqual(wire.FrameType.fs_reply, peeled.frame.ftype);
            try t.expect(std.mem.indexOf(u8, peeled.frame.payload, "\"ok\":false") != null);
            try t.expectEqual(FsJob.State.running, job.state);
        }
    }
}

test "cross moves and no-replace copies use the durable cancellation fence" {
    try std.testing.expect(cancelNeedsDurableFence(.cross_copy, true, false));
    try std.testing.expect(cancelNeedsDurableFence(.cross_copy, false, true));
    try std.testing.expect(!cancelNeedsDurableFence(.cross_copy, false, false));
    try std.testing.expect(!cancelNeedsDurableFence(.copy, true, true));
}

test "only source-safety phases bypass the client retry policy" {
    try std.testing.expect(!phaseNeedsSafetyRecovery(.{ .id = 1, .op = "cross_copy", .delete_src = true, .phase = "rename_planned" }));
    try std.testing.expect(phaseNeedsSafetyRecovery(.{ .id = 1, .op = "cross_copy", .delete_src = true, .phase = "copied" }));
    try std.testing.expect(phaseNeedsSafetyRecovery(.{ .id = 1, .op = "cross_copy", .delete_src = true, .phase = "deleting" }));
    try std.testing.expect(!phaseNeedsSafetyRecovery(.{ .id = 1, .op = "cross_copy", .delete_src = true, .phase = "source_deleted" }));
    try std.testing.expect(!phaseNeedsSafetyRecovery(.{ .id = 1, .op = "copy", .phase = "copied" }));
}

test "journal filenames reserve ids even when their payload is unreadable" {
    try std.testing.expectEqual(@as(?u64, 42), journalIdFromName("42.json"));
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), journalIdFromName("18446744073709551615.json"));
    try std.testing.expect(journalIdFromName("42.cancel") == null);
    try std.testing.expect(journalIdFromName("bad.json") == null);
}

test "cancel-marked failed no-replace copy still requires recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dir = try std.fmt.allocPrint(arena.allocator(), ".zig-cache/tmp/{s}/jobs", .{&tmp.sub_path});
    try fsjournal.save(dir, .{ .id = 44, .op = "cross_copy", .state = "failed", .no_replace = true });
    try std.testing.expectEqual(fsjournal.CancelResult.requested, (try fsjournal.tryRequestRecoveryCancel(std.testing.allocator, dir, 44)).?);
    try std.testing.expect(needsSafetyRecovery(dir, .{
        .id = 44,
        .op = "cross_copy",
        .state = "failed",
        .no_replace = true,
    }));
}
