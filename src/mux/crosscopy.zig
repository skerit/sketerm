//! The `cross_copy` job: a durable copy or move between two hosts,
//! coordinated by the daemon whose helper runs it.
//!
//! Each side is an fsdrive client of that host's daemon; the bytes
//! are pipelined through a bounded read/write window (`transferBytes`)
//! and never touch the client machine. A dropped link is redialled
//! in-helper from the exact byte offset; a move stages the destination
//! and quarantines the source so a crash at any phase resumes from the
//! journal. The helper runtime it shares with every other job --
//! progress emission, the journal, the durable-outcome state -- stays
//! in fsjob.zig and is reached through the aliases below.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;
const fsserve = @import("fsserve.zig");
const fsjournal = @import("fsjournal.zig");
const muxclient = @import("client.zig");
const fsdrive = @import("../ipc/fsdrive.zig");
const fsjob = @import("fsjob.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;

const Spec = fsjob.Spec;
const CrossDurable = fsjob.CrossDurable;
const Progress = fsjob.Progress;
const PART_SUFFIX = fsjob.PART_SUFFIX;
const LINK_PART_SUFFIX = fsjob.LINK_PART_SUFFIX;
const emit = fsjob.emit;
const emitError = fsjob.emitError;
const emitErrorKind = fsjob.emitErrorKind;
const emitCanceled = fsjob.emitCanceled;
const saveCrossPhase = fsjob.saveCrossPhase;
const emitCrossPhase = fsjob.emitCrossPhase;
const persistCrossPhase = fsjob.persistCrossPhase;
const emitCopyDone = fsjob.emitCopyDone;
const stampEntry = fsjob.stampEntry;
const cancelRequested = fsjob.cancelRequested;
const sleepMs = fsjob.sleepMs;

fn connectHostFs(allocator: std.mem.Allocator, host: []const u8) !fsdrive.Fs {
    const conn = if (host.len == 0)
        try muxclient.Conn.connectLocalAutostart(allocator)
    else blk: {
        // The daemon host's own config governs its outbound UDP;
        // journal-resumed jobs read the CURRENT value, not a stale
        // copy journaled at submission time.
        var cfg = @import("../config.zig").Config.load(allocator);
        defer cfg.deinit();
        break :blk try muxclient.Conn.connectRemote(allocator, host, cfg.muxConnectOptions());
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
pub fn durableCancelRequested(journal_dir: []const u8, job_id: u64) bool {
    if (fsjob.durable_state.delete_started) return false;
    if (fsjob.durable_state.cancel_requested) return true;
    if (job_id == 0 or journal_dir.len == 0) return false;
    fsjob.durable_state.cancel_requested = fsjournal.cancelRequested(journal_dir, job_id);
    return fsjob.durable_state.cancel_requested;
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
        const phase = fsjob.durable_state.progress.phase.slice();
        _ = durableCancelRequested(self.journal_dir, self.job_id);
        if (fsjob.durable_state.cancel_requested and fsjournal.phaseRank(phase) < fsjournal.phaseRank("deleting")) {
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
        const part = std.fmt.bufPrint(&part_buf, "{s}" ++ PART_SUFFIX, .{dst_path}) catch {
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
        const temp = std.fmt.bufPrint(&temp_buf, "{s}" ++ LINK_PART_SUFFIX ++ "-{d}", .{ dst_path, temp_id }) catch {
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
        const part = std.fmt.bufPrint(&part_buf, "{s}" ++ PART_SUFFIX, .{stage}) catch {
            self.fail("destination staging path is too long: {s}", .{tailOf(stage)});
            return false;
        };
        if (!self.deleteOwnedDestinationPath(part)) return false;
        const link_part = std.fmt.bufPrint(&part_buf, "{s}" ++ LINK_PART_SUFFIX ++ "-{d}", .{ stage, self.job_id }) catch return false;
        if (!self.deleteOwnedDestinationPath(link_part)) return false;
        const legacy_link_part = std.fmt.bufPrint(&part_buf, "{s}" ++ LINK_PART_SUFFIX, .{stage}) catch return false;
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
                .file => std.fmt.bufPrint(&part_buf, "{s}" ++ PART_SUFFIX, .{destination}),
                .link => std.fmt.bufPrint(&part_buf, "{s}" ++ LINK_PART_SUFFIX ++ "-{d}", .{ destination, self.job_id }),
                else => continue,
            } catch {
                self.fail("destination staging path is too long: {s}", .{tailOf(destination)});
                return false;
            };
            if (!self.deleteOwnedDestinationPath(part)) return false;
            if (item.kind == .link) {
                const legacy = std.fmt.bufPrint(&part_buf, "{s}" ++ LINK_PART_SUFFIX, .{destination}) catch return false;
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
                fsjob.durable_state.cancel_requested = true;
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
        fsjob.durable_state.cancel_requested = true;
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
    fsjob.durable_state.retryable_cleanup = true;
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
    fsjob.durable_state.cancel_requested = true;
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
        fsjob.durable_state.progress.phase.set("source_deleted");
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

pub fn run(allocator: std.mem.Allocator, spec_in: Spec) u8 {
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
    fsjob.durable_state.delete_started = moveDeletionStarted(spec.delete_src, spec.phase);
    const reconcile_staged_install = !spec.delete_src and spec.no_replace and
        fsjournal.phaseRank(spec.phase) >= fsjournal.phaseRank("destination_staged");
    if (cancelRequested(spec) and !reconcile_staged_install) return finishMoveCancellation(allocator, spec);
    const src_label = if (spec.src_host.len == 0) "local" else spec.src_host;
    const dst_label = if (spec.dst_host.len == 0) "local" else spec.dst_host;
    var src = connectHostFsRetrying(allocator, spec.src_host, .src, spec.dial_tries, spec, reconcile_staged_install) orelse
        return if (reconcile_staged_install)
            cancelCleanupRetry("cancel requested; reconnecting later to reconcile the destination install")
        else if (fsjob.durable_state.cancel_requested)
            finishMoveCancellation(allocator, spec)
        else
            emitCrossDialFailure(spec, .src, src_label);
    defer src.deinit();
    var dst = connectHostFsRetrying(allocator, spec.dst_host, .dst, spec.dial_tries, spec, reconcile_staged_install) orelse
        return if (fsjob.durable_state.cancel_requested) finishMoveCancellation(allocator, spec) else emitCrossDialFailure(spec, .dst, dst_label);
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
                fsjob.durable_state.cancel_requested = true;
                return finishMoveCancellation(allocator, cancellationSpec(spec, "rename_planned", move_durable, &cc.progress));
            }
        }
        const rename_result = cc.tryRenameMove(spec.src, spec.dst, move_durable);
        if (rename_result == .moved) {
            fsjob.durable_state.delete_started = true;
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
                fsjob.durable_state.delete_started = false;
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
            return if (fsjob.durable_state.cancel_requested)
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
    fsjob.durable_state.delete_started = true;
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

// ── tests ───────────────────────────────────────────────────────

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
    fsjob.durable_state.cancel_requested = false;
    fsjob.durable_state.error_kind.len = 0;
    var copy = CrossCopy{
        .allocator = std.testing.allocator,
        .src = undefined,
        .dst = undefined,
        .src_host = "darkshire",
        .dst_host = "",
    };
    copy.fail("read small.txt on darkshire: permission denied", .{});
    _ = copy.emitFailure();
    try std.testing.expectEqualStrings("permanent", fsjob.durable_state.error_kind.slice());

    fsjob.durable_state.error_kind.len = 0;
    copy.retryable_transport = true;
    _ = copy.emitFailure();
    try std.testing.expectEqualStrings("transport", fsjob.durable_state.error_kind.slice());
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
    fsjob.durable_state.cancel_requested = false;
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
