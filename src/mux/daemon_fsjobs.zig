//! Subprocess file jobs (copy / delete_tree / hash / find / ...) —
//! spawn, journaling, recovery, progress relay — split out of
//! daemon.zig. Functions take the owning *Daemon and are aliased back
//! into Daemon.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const wire = @import("wire.zig");
const fsjournal = @import("fsjournal.zig");
const pathZ = @import("../util/pathz.zig").pathZ;
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;
const Session = dmod.Session;
const FsJob = dmod.FsJob;
const FsOpReq = @import("daemon_serve.zig").FsOpReq;
const nowMs = dmod.nowMs;
const wallMs = dmod.wallMs;
const fsReplyErr = @import("daemon_serve.zig").fsReplyErr;

// ── subprocess file jobs (copy / delete_tree / hash) ────────────

/// Cap on RETAINED finished jobs (job_list history). Running jobs
/// are never dropped.
pub const MAX_FINISHED_JOBS = 64;
/// Cap on one media_meta batch's separator-joined name list.
pub const MAX_MEDIA_BATCH_BYTES = 16 * 1024;
pub const MAX_TOKEN_JOBS = 1024;
const PREVIEW_ASSET_TTL_MS: i64 = 300_000;

pub fn fsStartJob(self: *Daemon, cl: *Client, r: FsOpReq) void {
    const op: FsJob.Op = if (std.mem.eql(u8, r.op, "copy"))
        .copy
    else if (std.mem.eql(u8, r.op, "delete_tree"))
        .delete_tree
    else if (std.mem.eql(u8, r.op, "find"))
        .find
    else if (std.mem.eql(u8, r.op, "grep"))
        .grep
    else if (std.mem.eql(u8, r.op, "extract"))
        .extract
    else if (std.mem.eql(u8, r.op, "archive_create"))
        .archive_create
    else if (std.mem.eql(u8, r.op, "archive_list"))
        .archive_list
    else if (std.mem.eql(u8, r.op, "archive_extract"))
        .archive_extract
    else if (std.mem.eql(u8, r.op, "trash"))
        .trash
    else if (std.mem.eql(u8, r.op, "trash_restore"))
        .trash_restore
    else if (std.mem.eql(u8, r.op, "cross_copy"))
        .cross_copy
    else if (std.mem.eql(u8, r.op, "panelize"))
        .panelize
    else if (std.mem.eql(u8, r.op, "live_find"))
        .live_find
    else if (std.mem.eql(u8, r.op, "thumbnail"))
        .thumbnail
    else if (std.mem.eql(u8, r.op, "preview"))
        .preview
    else if (std.mem.eql(u8, r.op, "preview_transport"))
        .preview_transport
    else if (std.mem.eql(u8, r.op, "dir_size"))
        .dir_size
    else if (std.mem.eql(u8, r.op, "perm_tree"))
        .perm_tree
    else if (std.mem.eql(u8, r.op, "media_meta"))
        .media_meta
    else
        .hash;
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
    if (op == .media_meta) {
        if (r.pattern.len == 0) return fsReplyErr(cl, r.req, "media_meta needs at least one name");
        if (r.pattern.len > MAX_MEDIA_BATCH_BYTES) return fsReplyErr(cl, r.req, "media_meta batch too large");
    }

    // Idempotent submission closes the crash window where the job
    // started but its reply never reached the caller. Claiming the
    // existing job also resumes its event stream after reconnect.
    if (r.client_token.len > 0) {
        for (self.fs_jobs.items) |existing| {
            if (!std.mem.eql(u8, existing.client_token, r.client_token)) continue;
            if (existing.terminal_pending) {
                saveFsJob(self, existing) catch return fsReplyErr(cl, r.req, "cannot persist terminal job state");
                existing.terminal_pending = false;
            }
            existing.owner = cl;
            cl.queueJson(.fs_reply, .{
                .req = r.req,
                .ok = true,
                .job = existing.id,
                .state = @tagName(existing.state),
                .done = existing.done,
                .total = existing.total,
                .message = existing.message[0..existing.message_len],
            });
            if (existing.finished()) {
                fsJobEmit(self, existing, switch (existing.state) {
                    .done => "done",
                    .canceled => "canceled",
                    else => "error",
                });
            }
            return;
        }
    }
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
    const job = spawnFsJob(self, cl, op, self.next_fs_job_id, .{
        .src = r.path,
        .dst = r.to,
        .pattern = r.pattern,
        .src_host = r.src_host,
        .dst_host = r.dst_host,
        .client_token = r.client_token,
        .resumable = r.@"resume",
        .within_ms = r.within_ms,
        .max_matches = r.max_matches,
        .perm = .{ .mode = r.mode, .uid = if (r.uid) |v| @as(i64, v) else -1, .gid = if (r.gid) |v| @as(i64, v) else -1 },
        .copy = .{ .conflict = r.conflict, .dir_mode = r.dir_mode },
        .image_codecs = r.image_codecs,
        .wire_cache = r.wire_cache,
        .owns_dst = op == .panelize and r.delete_destination,
        .owns_src = op == .preview_transport and r.delete_source,
        .delete_src = op == .cross_copy and r.delete_src,
        .dial_tries = r.dial_tries,
    }) catch
        return fsReplyErr(cl, r.req, "cannot start job");
    if (source_owner) |producer| {
        producer.owns_dst = false;
        producer.cleanup_at_ms = nowMs();
    }
    self.next_fs_job_id = job.id + 1;
    cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true, .job = job.id });
}

/// Short-lived client-owned probes: no journal, no history, killed
/// with the requesting client. They report a view's decoration, not
/// a mutation worth recovering.
pub fn ephemeralOp(op: FsJob.Op) bool {
    return op == .thumbnail or op == .preview or op == .preview_transport or op == .dir_size or op == .media_meta;
}

/// Recursive-permission arguments; -1 keeps the current owner or
/// group, mode 0 keeps the current mode.
pub const PermArgs = struct { mode: u32 = 0, uid: i64 = -1, gid: i64 = -1 };

/// Copy-collision arguments, forwarded verbatim to the helper.
pub const CopyArgs = struct { conflict: []const u8 = "", dir_mode: []const u8 = "" };

/// Everything a job run needs beyond its op and id. One struct so
/// call sites name what they set and default the rest.
pub const FsJobArgs = struct {
    src: []const u8 = "",
    dst: []const u8 = "",
    pattern: []const u8 = "",
    src_host: []const u8 = "",
    dst_host: []const u8 = "",
    client_token: []const u8 = "",
    resumable: bool = false,
    within_ms: u64 = 0,
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
    /// NOT journaled: a respawn dials with the full budget.
    dial_tries: u32 = 0,
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
        .max_matches = max_matches,
        .client_token = client_token,
        .mode = perm.mode,
        .uid = perm.uid,
        .gid = perm.gid,
        .conflict = copy.conflict,
        .dir_mode = copy.dir_mode,
        .image_codecs = image_codecs,
        .wire_cache = args.wire_cache,
        .delete_source = args.owns_src,
        .delete_src = args.delete_src,
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
        .conflict = conflict_owned,
        .resumable = resumable,
        .ephemeral = ephemeral,
        .owns_dst = args.owns_dst,
        .owns_src = args.owns_src,
        .delete_src = args.delete_src,
    };
    job_initialized = true;
    // The job owns the read end from here on; its deinit closes it,
    // so the pipe errdefer must not close it a second time.
    out_pipe[0] = -1;
    var job_owned = true;
    errdefer if (job_owned) job.deinit(true);
    self.fs_jobs.append(self.allocator, job) catch return error.OutOfMemory;
    saveFsJob(self, job) catch {
        _ = self.fs_jobs.pop();
        deleteFsJobJournal(self, id);
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
        deleteFsJobJournal(self, id);
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

pub fn journalFsJob(self: *Daemon, job: *FsJob) void {
    saveFsJob(self, job) catch {};
}

pub fn saveFsJob(self: *Daemon, job: *FsJob) !void {
    if (self.fs_job_dir.len == 0 or job.ephemeral) return;
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
        .delete_src = job.delete_src,
        .pid = job.pid,
        .done = job.done,
        .total = job.total,
        .resumed_from = job.resumed_from,
        .message = job.message[0..job.message_len],
        .client_token = job.client_token,
        .acknowledged = job.acknowledged,
    });
}

pub fn deleteFsJobJournal(self: *Daemon, id: u64) void {
    var path_buf: [4096:0]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{d}.json", .{ self.fs_job_dir, id }) catch return;
    _ = c.unlink(path.ptr);
}

pub fn restoredFsJob(self: *Daemon, rec: fsjournal.Record, op: FsJob.Op, state: FsJob.State) ?*FsJob {
    const src = self.allocator.dupe(u8, rec.src) catch return null;
    errdefer self.allocator.free(src);
    const dst = self.allocator.dupe(u8, rec.dst) catch return null;
    errdefer self.allocator.free(dst);
    const pattern = self.allocator.dupe(u8, rec.pattern) catch return null;
    errdefer self.allocator.free(pattern);
    const src_host = self.allocator.dupe(u8, rec.src_host) catch return null;
    errdefer self.allocator.free(src_host);
    const dst_host = self.allocator.dupe(u8, rec.dst_host) catch return null;
    errdefer self.allocator.free(dst_host);
    const client_token = self.allocator.dupe(u8, rec.client_token) catch return null;
    errdefer self.allocator.free(client_token);
    const conflict = self.allocator.dupe(u8, rec.conflict) catch return null;
    errdefer self.allocator.free(conflict);
    const job = self.allocator.create(FsJob) catch return null;
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
        .src = src,
        .dst = dst,
        .pattern = pattern,
        .src_host = src_host,
        .dst_host = dst_host,
        .client_token = client_token,
        .conflict = conflict,
        .acknowledged = rec.acknowledged,
        .resumable = rec.@"resume",
        .delete_src = rec.delete_src,
    };
    job.setMessage(rec.message);
    self.fs_jobs.append(self.allocator, job) catch {
        job.deinit(false);
        return null;
    };
    return job;
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
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        var pbuf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ self.fs_job_dir, name }) catch continue;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const parsed = fsjournal.load(arena_state.allocator(), path) catch continue;
        defer parsed.deinit();
        const rec = parsed.value;
        const op = fsOpFromName(rec.op) orelse continue;
        self.next_fs_job_id = @max(self.next_fs_job_id, rec.id + 1);
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
        if (state == .done or state == .failed or state == .canceled) {
            _ = restoredFsJob(self, rec, op, state);
            continue;
        }
        if (rec.pid > 0 and c.kill(@intCast(rec.pid), 0) == 0) {
            _ = restoredFsJob(self, rec, op, state);
            continue;
        }
        if (op == .copy or op == .cross_copy or op == .live_find) {
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
                .resumable = true,
                .copy = .{ .conflict = rec.conflict },
                .delete_src = rec.delete_src,
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
        if (job.out_fd >= 0 or job.finished() or job.pid <= 0) continue;
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
        if (std.mem.eql(u8, state, "done")) {
            job.state = .done;
            fsJobEmit(self, job, "done");
        } else {
            job.state = .failed;
            job.setMessage(parsed.value.message);
            fsJobEmit(self, job, "error");
        }
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
            // SIGCONT first: a SIGSTOPped child never dispatches
            // SIGKILL... actually SIGKILL cannot be blocked even
            // stopped, but the CONT keeps wait semantics simple.
            _ = c.kill(-job.pid, c.SIGCONT);
            _ = c.kill(-job.pid, c.SIGKILL);
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
        _ = c.kill(-job.pid, c.SIGSTOP);
        job.state = .paused;
        journalFsJob(self, job);
        fsJobEmit(self, job, "paused");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "job_resume")) {
        if (job.finished()) return fsReplyErr(cl, r.req, "job already finished");
        _ = c.kill(-job.pid, c.SIGCONT);
        job.state = .running;
        journalFsJob(self, job);
        fsJobEmit(self, job, "resumed");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else {
        fsReplyErr(cl, r.req, "unknown job op");
    }
}

/// Push one fs_job event toward the owner (if still alive).
pub fn fsJobEmit(self: *Daemon, job: *FsJob, ev: []const u8) void {
    _ = self;
    const owner = job.owner orelse return;
    if (owner.dead) return;
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
        /// Progress detail: the entry in flight (present only when
        /// it CHANGED — the helper does not repeat it) and the
        /// entry counters for tree operations.
        file: []const u8 = "",
        files_done: u64 = 0,
        files_total: u64 = 0,
        /// media_meta: extracted key/value pairs for one file, plus
        /// whether the helper served them from its cache.
        meta: []const MetaKV = &.{},
        cached: bool = false,
        /// done: the result path is a PERSISTENT host-side cache
        /// file, not a temp asset — nobody may unlink it.
        keep: bool = false,
    };
    const parsed = std.json.parseFromSlice(Ev, self.allocator, line, .{
        .ignore_unknown_fields = true,
    }) catch return;
    defer parsed.deinit();
    const e = parsed.value;
    if (std.mem.eql(u8, e.ev, "asset")) {
        job.done_path_len = @min(e.path.len, job.done_path.len);
        @memcpy(job.done_path[0..job.done_path_len], e.path[0..job.done_path_len]);
        job.cleanup_at_ms = if (job.owner == null or job.owner.?.dead) nowMs() else nowMs() + PREVIEW_ASSET_TTL_MS;
        return;
    }
    if (std.mem.eql(u8, e.ev, "match") or std.mem.eql(u8, e.ev, "unmatch") or
        std.mem.eql(u8, e.ev, "resync") or std.mem.eql(u8, e.ev, "ready") or
        std.mem.eql(u8, e.ev, "reject"))
    {
        // Streaming query events: forwarded verbatim toward the
        // owner (never stored -- the stream IS the result). `ready`
        // is a live query's status line and repeats whenever one of
        // its bounds is newly hit; `reject` is one output line a
        // panelize command produced that was not a usable path.
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
            });
        }
        return;
    }
    job.done = e.done;
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
    if (e.files_done > job.files_done) job.files_done = e.files_done;
    if (e.files_total > job.files_total) job.files_total = e.files_total;
    if (std.mem.eql(u8, e.ev, "done")) {
        job.matches = if (e.matches > 0) e.matches else job.matches;
        job.truncated = e.truncated;
        job.rejected = e.rejected;
        job.exit_status = e.exit_status;
        // Cancel raced completion: the work DID finish — honesty
        // says report done, not canceled.
        job.state = .done;
        if (e.hash.len == 64) {
            @memcpy(&job.hash_hex, e.hash[0..64]);
            job.has_hash = true;
        }
        job.done_path_len = @min(e.path.len, job.done_path.len);
        @memcpy(job.done_path[0..job.done_path_len], e.path[0..job.done_path_len]);
        job.done_kept = e.keep;
        job.done_text_len = @min(e.text.len, job.done_text.len);
        @memcpy(job.done_text[0..job.done_text_len], e.text[0..job.done_text_len]);
        if (job.owns_dst or job.owns_src or job.op == .thumbnail or job.op == .preview or job.op == .preview_transport)
            job.cleanup_at_ms = if (job.owner == null or job.owner.?.dead) nowMs() else nowMs() + PREVIEW_ASSET_TTL_MS;
        saveFsJob(self, job) catch {
            job.terminal_pending = true;
            return;
        };
        fsJobEmit(self, job, "done");
    } else if (std.mem.eql(u8, e.ev, "error")) {
        job.state = .failed;
        job.setMessage(e.message);
        job.err_kind_len = @min(e.kind.len, job.err_kind.len);
        @memcpy(job.err_kind[0..job.err_kind_len], e.kind[0..job.err_kind_len]);
        saveFsJob(self, job) catch {
            job.terminal_pending = true;
            return;
        };
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
    job.releaseOwnedSource();
    _ = c.close(job.out_fd);
    job.out_fd = -1;
    var emit_terminal = job.terminal_pending;
    if (!job.finished()) {
        job.state = .failed;
        job.setMessage("job helper died");
        emit_terminal = true;
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
