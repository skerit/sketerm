//! Git jobs: `git status` and `git diff` run on the host that owns the repository.

const std = @import("std");
const c = @import("../../c.zig").c;
const gitstatus = @import("../../filebrowser/gitstatus.zig");
const gitdiff = @import("../../editor/gitdiff.zig");
const fsjob = @import("../fsjob.zig");
const Job = fsjob.Job;

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
pub fn runGitStatus(job: *const Job) u8 {
    const allocator = job.allocator;
    const spec = job.spec;
    var cmd: [4400:0]u8 = undefined;
    var w = std.Io.Writer.fixed(cmd[0 .. cmd.len - 1]);
    w.writeAll("cd '") catch return job.emitError("path too long");
    for (spec.src) |ch| {
        if (ch == '\'') w.writeAll("'\\''") catch return job.emitError("path too long") else w.writeByte(ch) catch return job.emitError("path too long");
    }
    // \x01 closes the status stream, \x02 closes the prefix — and the
    // latter is only printed when rev-parse SUCCEEDED, which is the
    // "this is a repository" answer that survives a git too old for
    // porcelain v2 (its status output would be empty).
    w.print(
        "' 2>/dev/null && git status --porcelain=v2 --branch --ignored -z 2>/dev/null | head -c {d} && printf '\\x01' && git rev-parse --show-prefix 2>/dev/null && printf '\\x02'",
        .{GIT_STATUS_BYTES},
    ) catch return job.emitError("path too long");
    cmd[w.buffered().len] = 0;
    const fp = c.popen(&cmd, "r") orelse return job.emitError("cannot run git");
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
        job.emit(.{ .ev = "done", .done = @as(u64, 0), .total = @as(u64, 0) });
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
            job.emit(.{
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
    job.emit(.{
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
    job.emit(.{ .ev = "done", .done = emitted, .total = emitted });
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
pub fn runGitDiff(job: *const Job) u8 {
    const allocator = job.allocator;
    const spec = job.spec;
    if (spec.src.len == 0) return job.emitError("git_diff needs a path");
    const dir = std.fs.path.dirname(spec.src) orelse "/";
    const base = std.fs.path.basename(spec.src);
    if (base.len == 0) return job.emitError("git_diff needs a file, not a directory");

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

        const fp = c.popen(&cmd, "r") orelse return job.emitError("cannot run git");
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
        if (oom) return job.emitError("git diff too large");

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

        const lines = gitdiff.parseUnified(allocator, text) catch return job.emitError("out of memory parsing diff");
        defer allocator.free(lines);
        const runs = gitdiff.runsFromLines(allocator, lines) catch return job.emitError("out of memory folding diff");
        defer allocator.free(runs);
        var emitted: u64 = 0;
        for (runs) |r| {
            if (emitted >= GIT_DIFF_RUNS) {
                truncated = true;
                break;
            }
            job.emit(.{
                .ev = "line",
                .line = @as(u64, r.line),
                .size = @as(u64, r.count),
                .kind = gitdiff.kindName(r.kind),
            });
            emitted += 1;
        }
        job.emit(.{
            .ev = "repo",
            .repo = in_repo,
            .tracked = tracked,
            .initial = in_repo and !have_head,
            .truncated = truncated,
        });
        job.emit(.{ .ev = "done", .done = emitted, .total = emitted });
        return 0;
    }
    return job.emitError("path too long");
}
