//! The file service: `fs_op` (stat/list/read/mkdir/rename/delete/...
//! plus live views and incremental listings), `fs_write`, the inotify
//! delta pump behind live views, and `openChecked`, the one way the
//! daemon opens a client-named path. Split out of daemon_serve.zig;
//! functions take the owning *Daemon and are aliased back into Daemon.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("log.zig");
const wire = @import("wire.zig");
const platform = @import("../util/platform.zig");
const selfexec = @import("selfexec.zig");
const fsserve = @import("fsserve.zig");
const fsjob = @import("fsjob.zig");
const daemon_fsjobs = @import("daemon_fsjobs.zig");
const pulse = @import("pulse.zig");
const snapshot = @import("snapshot.zig");
const dmod = @import("daemon.zig");
const Daemon = dmod.Daemon;
const Client = dmod.Client;
const Worker = dmod.Worker;
const Session = dmod.Session;
const Channel = dmod.Channel;
const Upload = dmod.Upload;
const Download = dmod.Download;
const FsView = dmod.FsView;
const SpawnReq = dmod.SpawnReq;
const AttachReq = dmod.AttachReq;
const WorkerReady = dmod.WorkerReady;
const WorkerMeta = dmod.WorkerMeta;
const WorkerPush = dmod.WorkerPush;
const nowMs = @import("../util/clock.zig").nowMs;
const cwdOfPid = dmod.cwdOfPid;
const pathZ = @import("../util/pathz.zig").pathZ;
const version = @import("../version.zig");
const cast_rec = @import("cast.zig");
const opuscodec = @import("opuscodec.zig");
const build_options = @import("build_options");
const wsproto = @import("../winstream/proto.zig");
const wallMs = @import("../util/clock.zig").wallMs;
const webstore = @import("webstore.zig");
const webprofiles = @import("../ipc/webprofiles.zig");
const webfindbin = @import("../web/findbin.zig");
const capabilities = @import("capabilities.zig");

const OpenKind = enum {
    file,
    file_or_dir,

    fn admits(kind: OpenKind, mode: c.mode_t) bool {
        const fmt = mode & c.S_IFMT;
        return switch (kind) {
            .file => fmt == c.S_IFREG,
            .file_or_dir => fmt == c.S_IFREG or fmt == c.S_IFDIR,
        };
    }

    fn refusal(kind: OpenKind) []const u8 {
        return switch (kind) {
            .file => "path is not a regular file",
            .file_or_dir => "path is not a regular file or directory",
        };
    }
};

const Opened = union(enum) {
    fd: c_int,
    /// Refused before or after the open; the client gets this text.
    refused: []const u8,
    /// open() failed; the negative return carries errno.
    failed: c_int,
};

/// Opens a client-controlled path so that the open itself is never the
/// hazard. The kind is checked with stat BEFORE open: a device node whose
/// open has side effects (/dev/watchdog arms a reboot on open alone) or a
/// FIFO with no peer is refused unopened, where a post-open check would
/// have opened it first. O_NONBLOCK then keeps a FIFO from parking the
/// daemon's single poll loop should one appear between the two calls,
/// and the fstat on the opened fd refuses anything that is not the
/// inode stat saw -- so a path swapped underneath is never used, only
/// opened once. That one residual open needs O_PATH to close, which the
/// portable libc set lacks; the swapper must already own the directory.
/// A path stat cannot see (ENOENT with O_CREAT, say) goes straight to
/// open and is held to the post-open kind check alone.
pub fn openChecked(path: [*:0]const u8, oflags: c_int, mode: c.mode_t, kind: OpenKind) Opened {
    var pre: c.struct_stat = undefined;
    const pre_ok = c.stat(path, &pre) == 0;
    if (pre_ok and !kind.admits(pre.st_mode)) return .{ .refused = kind.refusal() };
    const fd = c.open(path, oflags | c.O_CLOEXEC | c.O_NONBLOCK, mode);
    if (fd < 0) return .{ .failed = fd };
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) {
        _ = c.close(fd);
        return .{ .refused = "fstat failed" };
    }
    if (!kind.admits(st.st_mode)) {
        _ = c.close(fd);
        return .{ .refused = kind.refusal() };
    }
    if (pre_ok and (st.st_dev != pre.st_dev or st.st_ino != pre.st_ino)) {
        _ = c.close(fd);
        return .{ .refused = "path changed during open" };
    }
    return .{ .fd = fd };
}


// === File service (fs_op / fs_write / fs_delta) ================
// The file-browser surface (src/ui/browser/CLAUDE.md):
// rich one-round-trip listings, live directory views over inotify,
// and the small mutation verbs. Everything here is an INLINE job in
// the roadmap's terms — bounded work in the poll loop; recursive /
// long-running verbs arrive in phase 2 as subprocess jobs. NOT
// attach-scoped: in broker mode the broker itself serves these
// (fs clients never attach, so their fds are never handed off).

pub const FsOpReq = struct {
    req: u32 = 0,
    op: []const u8 = "",
    path: []const u8 = "",
    /// rename destination / symlink target / copy dst.
    to: []const u8 = "",
    view: u32 = 0,
    off: u64 = 0,
    len: u32 = 0,
    /// Job verbs: allow hash-verified resume of a staged partial.
    @"resume": bool = false,
    /// The top-level destination must still be absent when installed.
    no_replace: bool = false,
    /// copy: per-entry collision policy INSIDE a tree
    /// ("" = overwrite, "skip", "keep_both").
    conflict: []const u8 = "",
    /// copy onto an existing directory: "" / "merge" keeps
    /// destination-only entries, "replace" removes the tree first.
    dir_mode: []const u8 = "",
    /// job_cancel/job_pause/job_resume target.
    job: u64 = 0,
    /// find/grep search pattern.
    pattern: []const u8 = "",
    /// find: only entries modified within this window (0 = all).
    within_ms: u64 = 0,
    /// preview_stream: encode from this offset (a time seek restarts
    /// the transcode here).
    start_ms: u64 = 0,
    /// find: raise the match cap (0 = default 2000; hard 200k).
    max_matches: u64 = 0,
    mode: u32 = 0,
    uid: ?u32 = null,
    gid: ?u32 = null,
    size: u64 = 0,
    atime_ms: ?i64 = null,
    mtime_ms: ?i64 = null,
    src_host: []const u8 = "",
    dst_host: []const u8 = "",
    client_token: []const u8 = "",
    /// Stable logical-transfer identity kept across retry attempts:
    /// lets a resubmission adopt (and restart) the failed job that
    /// already owns staged data, instead of minting a fresh job whose
    /// randomized stage can never see it. Old daemons ignore it.
    transfer_token: []const u8 = "",
    /// A logical retry whose only purpose is durable cancellation
    /// recovery. A v2 coordinator arms the old job before restart.
    cancel_requested: bool = false,
    /// Comma-separated extended-attribute names to include with
    /// every entry (listings, stat and deltas).
    attrs: []const u8 = "",
    /// Preferred image transport codecs supported by the receiver.
    image_codecs: []const u8 = "",
    /// thumbnail: cache the codec bytes host-side and serve that
    /// persistent file (remote-serving mode; see fsjob.Spec).
    wire_cache: bool = false,
    /// A preview transport job owns and removes its source scratch.
    delete_source: bool = false,
    /// A panelize preview job owns the scratch path carried in `to`.
    delete_destination: bool = false,
    /// cross_copy: delete the verified source afterwards (a move).
    delete_src: bool = false,
    /// copy: hash-verify each file after copy (files_verify_copy).
    verify: bool = false,
    /// cross_copy: cap the initial per-side dial attempts (0 = full
    /// budget); direct remote-to-remote attempts fail fast with it.
    dial_tries: u32 = 0,
    /// install: the mtime_ns the client last saw on the destination.
    /// Null means "install unconditionally" (a fresh file, or a
    /// caller that does not guard against concurrent edits).
    expected_mtime_ns: ?i64 = null,
};

/// One change inside an fs_delta. upsert carries `entry`; del only
/// `name`.
pub const FsChange = struct {
    op: []const u8,
    name: []const u8,
    entry: ?fsserve.Entry = null,
};

/// Errno tags whose failure is the LINK or a backing network
/// filesystem dying rather than the filesystem refusing. Only these
/// earn the client's automatic retry; everything else (ACCES, NOENT,
/// NOSPC, IO, ...) answers the same way forever, and only the manual
/// Retry in the client makes sense for it.
const TRANSIENT_ERRNO_TAGS = [_][]const u8{
    "TIMEDOUT",
    "NOTCONN",
    "CONNRESET",
    "CONNREFUSED",
    "CONNABORTED",
    "HOSTUNREACH",
    "HOSTDOWN",
    "NETUNREACH",
    "NETDOWN",
    "NETRESET",
    "PIPE",
};

/// Classify an fs_reply error message by the errno tag it carries
/// (fsserve.errnoName spells failures as bare tags like "ACCES").
pub fn fsErrKind(msg: []const u8) []const u8 {
    for (TRANSIENT_ERRNO_TAGS) |tag| {
        if (hasErrnoToken(msg, tag)) return "transport";
    }
    return "permanent";
}

fn hasErrnoToken(msg: []const u8, tag: []const u8) bool {
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, msg, start, tag)) |idx| : (start = idx + 1) {
        const boundary_before = idx == 0 or !std.ascii.isAlphanumeric(msg[idx - 1]);
        const end = idx + tag.len;
        const boundary_after = end == msg.len or !std.ascii.isAlphanumeric(msg[end]);
        if (boundary_before and boundary_after) return true;
    }
    return false;
}

const FsStatvfs = struct { bsize: u64, frsize: u64, blocks: u64, bfree: u64, bavail: u64, files: u64, ffree: u64, namemax: u64 };

/// musl's `struct statvfs` carries an anonymous bitfield that translate-c
/// turns opaque, so on those targets the (verified, 64-bit LE) layout is
/// declared by hand rather than serving made-up numbers as `bavail = 0`.
const MuslStatvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
    f_type: c_uint,
    __reserved: [5]c_int,
};

fn fsStatvfs(path: [*:0]const u8) ?FsStatvfs {
    if (comptime @typeInfo(c.struct_statvfs) == .@"opaque") {
        comptime {
            if (@sizeOf(c_ulong) != 8 or @import("builtin").cpu.arch.endian() != .little)
                @compileError("hand-declared musl statvfs layout is only verified for 64-bit little-endian targets");
            std.debug.assert(@sizeOf(MuslStatvfs) == 112);
            std.debug.assert(@offsetOf(MuslStatvfs, "f_bavail") == 32);
            std.debug.assert(@offsetOf(MuslStatvfs, "f_namemax") == 80);
        }
        const S = struct {
            extern "c" fn statvfs(path: [*:0]const u8, buf: *MuslStatvfs) c_int;
        };
        var st: MuslStatvfs = undefined;
        if (S.statvfs(path, &st) != 0) return null;
        return .{ .bsize = st.f_bsize, .frsize = st.f_frsize, .blocks = st.f_blocks, .bfree = st.f_bfree, .bavail = st.f_bavail, .files = st.f_files, .ffree = st.f_ffree, .namemax = st.f_namemax };
    }
    var st: c.struct_statvfs = undefined;
    if (c.statvfs(path, &st) != 0) return null;
    return .{ .bsize = st.f_bsize, .frsize = st.f_frsize, .blocks = st.f_blocks, .bfree = st.f_bfree, .bavail = st.f_bavail, .files = st.f_files, .ffree = st.f_ffree, .namemax = st.f_namemax };
}

pub fn fsReplyErr(cl: *Client, req: u32, msg: []const u8) void {
    cl.queueJson(.fs_reply, .{ .req = req, .ok = false, .@"error" = msg, .kind = fsErrKind(msg) });
}

test "openChecked refuses a FIFO and a device node without opening them" {
    const t = std.testing;
    var dir_buf: [64]u8 = undefined;
    @memcpy(dir_buf[0..27], "/tmp/sketerm-openck-XXXXXX\x00");
    const dir = std.mem.span(@as([*:0]u8, @ptrCast(c.mkdtemp(@ptrCast(&dir_buf)) orelse return error.SkipZigTest)));
    var fifo_z: [96]u8 = undefined;
    const fifo = try std.fmt.bufPrintZ(&fifo_z, "{s}/fifo", .{dir});
    var reg_z: [96]u8 = undefined;
    const reg = try std.fmt.bufPrintZ(&reg_z, "{s}/reg", .{dir});
    defer {
        _ = c.unlink(fifo.ptr);
        _ = c.unlink(reg.ptr);
        _ = c.rmdir(dir.ptr);
    }
    try t.expect(c.mkfifo(fifo.ptr, 0o600) == 0);
    // A blocking O_RDONLY open of a writer-less FIFO never returns; the
    // refusal proves the open was never attempted.
    switch (openChecked(fifo.ptr, c.O_RDONLY, 0, .file)) {
        .refused => |why| try t.expectEqualStrings("path is not a regular file", why),
        else => return error.TestUnexpectedResult,
    }
    switch (openChecked(fifo.ptr, c.O_WRONLY, 0, .file)) {
        .refused => {},
        else => return error.TestUnexpectedResult,
    }
    switch (openChecked("/dev/null", c.O_RDONLY, 0, .file_or_dir)) {
        .refused => |why| try t.expectEqualStrings("path is not a regular file or directory", why),
        else => return error.TestUnexpectedResult,
    }
    // A directory is admitted only where the caller allows one.
    switch (openChecked(dir.ptr, c.O_RDONLY, 0, .file)) {
        .refused => {},
        else => return error.TestUnexpectedResult,
    }
    switch (openChecked(dir.ptr, c.O_RDONLY, 0, .file_or_dir)) {
        .fd => |fd| _ = c.close(fd),
        else => return error.TestUnexpectedResult,
    }
    // A regular file that does not exist yet is created (fs_write's
    // O_CREAT shape) and then held to the post-open check.
    switch (openChecked(reg.ptr, c.O_WRONLY | c.O_CREAT, @as(c.mode_t, 0o644), .file)) {
        .fd => |fd| _ = c.close(fd),
        else => return error.TestUnexpectedResult,
    }
    switch (openChecked(reg.ptr, c.O_RDONLY, 0, .file)) {
        .fd => |fd| _ = c.close(fd),
        else => return error.TestUnexpectedResult,
    }
    var missing_z: [96]u8 = undefined;
    const missing = try std.fmt.bufPrintZ(&missing_z, "{s}/missing", .{dir});
    switch (openChecked(missing.ptr, c.O_RDONLY, 0, .file)) {
        .failed => |rc| try t.expect(rc < 0),
        else => return error.TestUnexpectedResult,
    }
}

test "fs_reply errors classify transient link failures as transport" {
    try std.testing.expectEqualStrings("permanent", fsErrKind("ACCES"));
    try std.testing.expectEqualStrings("permanent", fsErrKind("NOENT"));
    try std.testing.expectEqualStrings("permanent", fsErrKind("NOSPC"));
    try std.testing.expectEqualStrings("permanent", fsErrKind("cannot fsync directory parent"));
    try std.testing.expectEqualStrings("transport", fsErrKind("TIMEDOUT"));
    try std.testing.expectEqualStrings("transport", fsErrKind("read failed: CONNRESET"));
    // Tag must stand alone, never match inside a longer word.
    try std.testing.expectEqualStrings("permanent", fsErrKind("file PIPELINE.md is missing"));
}

/// fsync the directory a just-committed mutation changed, so it
/// survives a crash.
///
/// Best-effort BY DESIGN, and the one home for that decision: by the
/// time this runs the rename/mkdir/unlink has already landed and is
/// irrevocable. A filesystem that refuses a directory fsync (FUSE, NFS
/// and CIFS answer EROFS or EINVAL) used to make the reply `ok=false`,
/// which told the client nothing had happened while the operation had
/// in fact succeeded — the client then discarded its undo record and
/// showed "operation failed". `webext/install.zig`'s `syncBase` reached
/// the same conclusion for the same reason.
fn syncParentDir(path: []const u8, what: []const u8) void {
    const parent = std.fs.path.dirname(path) orelse return;
    var dz: [4096]u8 = undefined;
    const dir_z = pathZ(&dz, parent) catch return;
    const dfd = c.open(dir_z, c.O_RDONLY | c.O_DIRECTORY);
    if (dfd < 0) {
        log.info("fs {s}: cannot open '{s}' to fsync it; the change stands but is not yet durable", .{ what, parent });
        return;
    }
    defer _ = c.close(dfd);
    if (c.fsync(dfd) != 0)
        log.info("fs {s}: fsync of '{s}' refused ({s}); the change stands but is not yet durable", .{ what, parent, fsserve.errnoName(@as(c_int, -1)) });
}

pub fn handleFsOp(self: *Daemon, cl: *Client, payload: []const u8) void {
    const parsed = std.json.parseFromSlice(FsOpReq, self.allocator, payload, .{
        .ignore_unknown_fields = true,
    }) catch {
        cl.queueErr("bad fs_op");
        return;
    };
    defer parsed.deinit();
    const r = parsed.value;

    if (std.mem.eql(u8, r.op, "close_view")) return fsCloseView(self, cl, r);
    // Screen Recording is the DAEMON's permission, not the GUI's — it
    // is the process that captures — so the GUI has to ask over the
    // wire. Answered before the absolute-path check below: neither
    // verb takes a path.
    if (std.mem.eql(u8, r.op, "screen_perm")) return screenPerm(cl, r, false);
    if (std.mem.eql(u8, r.op, "screen_perm_request")) return screenPerm(cl, r, true);
    if (std.mem.startsWith(u8, r.op, "job_")) return self.fsJobOp(cl, r);
    // Every other verb takes an absolute path — the client resolves
    // ~ and relative input; the daemon never guesses a cwd here.
    if (r.path.len == 0 or r.path[0] != '/') return fsReplyErr(cl, r.req, "path must be absolute");
    // Job verbs are recognised straight off FsJob.Op's tag names, so
    // routing here and the dispatch in fsStartJob cannot drift apart
    // (a hand-maintained duplicate list silently dropped git_status /
    // diff / split / combine / secure_delete into "unknown fs op").
    if (@import("daemon_fsjobs.zig").jobOpFor(r.op) != null)
        return self.fsStartJob(cl, r);

    if (std.mem.eql(u8, r.op, "open_view")) {
        fsOpenView(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "list")) {
        // A refresh of a directory this client also watches gets its
        // snapshot boundary and child counts on that exact view. Old
        // clients omit `view`, so path matching remains the fallback.
        const view: ?*FsView = if (r.view != 0)
            fsViewForRefresh(self, cl, r)
        else for (self.fs_views.items) |v| {
            if (v.client == cl and !v.gone and std.mem.eql(u8, v.path, r.path)) break v;
        } else null;
        _ = fsStartListing(self, cl, r.req, if (view) |v| v.path else r.path, r.attrs, view);
    } else if (std.mem.eql(u8, r.op, "stat")) {
        fsStat(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "read")) {
        fsRead(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "install")) {
        fsInstall(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "apps")) {
        fsApps(self, cl, r);
    } else if (std.mem.eql(u8, r.op, "homedir")) {
        // Host identity for cache placement: thumbnails belong to
        // the machine that owns the files.
        var cache_buf: [4096]u8 = undefined;
        const home: []const u8 = if (c.getenv("HOME")) |h|
            std.mem.span(@as([*:0]const u8, @ptrCast(h)))
        else
            "/";
        const cache: []const u8 = if (c.getenv("XDG_CACHE_HOME")) |xc|
            std.mem.span(@as([*:0]const u8, @ptrCast(xc)))
        else
            std.fmt.bufPrint(&cache_buf, "{s}/.cache", .{home}) catch "/tmp";
        // The template directory is resolved HERE, on the host
        // that owns the files: "New from Template" on a remote tab
        // must offer that machine's templates, and only this
        // daemon can read its user-dirs.dirs.
        var config_buf: [4096]u8 = undefined;
        const config_home: []const u8 = if (c.getenv("XDG_CONFIG_HOME")) |xc|
            std.mem.span(@as([*:0]const u8, @ptrCast(xc)))
        else
            std.fmt.bufPrint(&config_buf, "{s}/.config", .{home}) catch "/tmp";
        var templates_buf: [4096]u8 = undefined;
        const templates = fsserve.templatesDir(home, config_home, &templates_buf);
        // The sidebar's user directories, only those that exist here.
        var body: [8192]u8 = undefined;
        const dirs_body = fsserve.readUserDirsFile(config_home, &body);
        var dir_bufs: [fsserve.user_dirs.len][4096]u8 = undefined;
        var dirs: [fsserve.user_dirs.len]struct { label: []const u8, path: []const u8 } = undefined;
        var ndirs: usize = 0;
        for (fsserve.user_dirs, 0..) |d, i| {
            const p = fsserve.userDirPath(dirs_body, d, home, &dir_bufs[i]) orelse continue;
            // xdg-user-dirs disables a directory by pointing it at "$HOME/".
            if (std.mem.eql(u8, std.mem.trimEnd(u8, p, "/"), std.mem.trimEnd(u8, home, "/"))) continue;
            var z: [4096]u8 = undefined;
            var st: c.struct_stat = undefined;
            const pz = pathZ(&z, p) catch continue;
            if (c.stat(pz, &st) != 0 or (st.st_mode & c.S_IFMT) != c.S_IFDIR) continue;
            dirs[ndirs] = .{ .label = d.label, .path = p };
            ndirs += 1;
        }
        // The trash is THIS user's on THIS host: a remote tab's Trash
        // place must open it, never the client user's path here.
        var trash_buf: [4096]u8 = undefined;
        const trash = fsserve.trashFilesDir(fsserve.envOpt("XDG_DATA_HOME"), home, &trash_buf) orelse "";
        cl.queueJson(.fs_reply, .{
            .req = r.req,
            .ok = true,
            .home = home,
            .cache = cache,
            .templates = templates,
            .trash = trash,
            .dirs = dirs[0..ndirs],
        });
    } else if (std.mem.eql(u8, r.op, "mkdir")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const rc = c.mkdir(p, 0o755);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        syncParentDir(r.path, "mkdir");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "rename")) {
        if (r.to.len == 0 or r.to[0] != '/') return fsReplyErr(cl, r.req, "to must be absolute");
        var z1: [4096]u8 = undefined;
        var z2: [4096]u8 = undefined;
        const from = pathZ(&z1, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const to = pathZ(&z2, r.to) catch return fsReplyErr(cl, r.req, "path too long");
        if (r.no_replace) {
            switch (@import("../util/platform.zig").renameNoReplace(from, to)) {
                .ok => {},
                .exists => return fsReplyErr(cl, r.req, "EXIST"),
                .cross_device => return fsReplyErr(cl, r.req, "XDEV"),
                .failed => |err| return fsReplyErr(cl, r.req, @tagName(err)),
            }
        } else {
            const rc = c.rename(from, to);
            if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        }
        syncParentDir(r.path, "rename source");
        syncParentDir(r.to, "rename destination");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "delete")) {
        // Single entry only: files/links unlink, EMPTY dirs rmdir.
        // Recursive delete is a phase-2 subprocess job — the poll
        // loop must never walk an unbounded tree.
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        var st: c.struct_stat = undefined;
        if (c.lstat(p, &st) != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, -1)));
        const rc = if ((st.st_mode & c.S_IFMT) == c.S_IFDIR) c.rmdir(p) else c.unlink(p);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        syncParentDir(r.path, "delete");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "unlink") or std.mem.eql(u8, r.op, "rmdir")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        var owned_temp = false;
        if (std.mem.eql(u8, r.op, "unlink")) {
            for (self.fs_jobs.items) |job| {
                if (job.ownsTempPath(r.path)) owned_temp = true;
            }
        }
        const rc = if (std.mem.eql(u8, r.op, "rmdir")) c.rmdir(p) else c.unlink(p);
        if (rc != 0 and !(owned_temp and std.posix.errno(rc) == .NOENT))
            return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        if (owned_temp) {
            for (self.fs_jobs.items) |job| {
                _ = job.releaseTempPath(r.path, nowMs());
            }
        }
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "create")) {
        // Empty-file create, O_EXCL so an existing file can never
        // be clobbered (the browser's Empty Document).
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const fd = c.open(p, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c.mode_t, 0o644));
        if (fd < 0) return fsReplyErr(cl, r.req, fsserve.errnoName(fd));
        _ = c.close(fd);
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "attr_list")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        cl.queueJson(.fs_reply, .{
            .req = r.req,
            .ok = true,
            .attrs = fsserve.listAttrs(arena_state.allocator(), p),
        });
    } else if (std.mem.eql(u8, r.op, "attr_set")) {
        // `pattern` = attribute name (user.* only), `to` = value
        // ("" removes). Attributes travel with the file, so this
        // is how metadata survives a copy to another host.
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        if (!std.mem.startsWith(u8, r.pattern, "user."))
            return fsReplyErr(cl, r.req, "attribute name must start with user.");
        if (!fsserve.setAttr(p, r.pattern, r.to)) return fsReplyErr(cl, r.req, "xattr set failed");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "tag_set")) {
        // `to` = comma-separated tags ("" clears). Rides the
        // user.sketerm.tags xattr, so tags travel with the file.
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        if (!fsserve.setTags(p, r.to)) return fsReplyErr(cl, r.req, "xattr set failed");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "symlink")) {
        // `to` is the link TARGET (may be relative by design);
        // `path` is where the link is created.
        if (r.to.len == 0) return fsReplyErr(cl, r.req, "missing target");
        var z1: [4096]u8 = undefined;
        var z2: [4096]u8 = undefined;
        const tgt = pathZ(&z1, r.to) catch return fsReplyErr(cl, r.req, "target too long");
        const link = pathZ(&z2, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const rc = c.symlink(tgt, link);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "hardlink")) {
        // `to` is the EXISTING file, `path` the new name. Both
        // impossibilities are reported as themselves rather than
        // as a bare errno: a hard link cannot cross filesystems
        // and cannot name a directory, and a client offering the
        // verb on stale device information deserves the reason.
        if (r.to.len == 0 or r.to[0] != '/') return fsReplyErr(cl, r.req, "to must be absolute");
        var z1: [4096]u8 = undefined;
        var z2: [4096]u8 = undefined;
        const tgt = pathZ(&z1, r.to) catch return fsReplyErr(cl, r.req, "target too long");
        const link = pathZ(&z2, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        var tst: c.struct_stat = undefined;
        if (c.lstat(tgt, &tst) != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, -1)));
        if ((tst.st_mode & c.S_IFMT) == c.S_IFDIR)
            return fsReplyErr(cl, r.req, "a directory cannot be hard linked");
        const parent = std.fs.path.dirname(r.path) orelse return fsReplyErr(cl, r.req, "link has no parent");
        var z3: [4096]u8 = undefined;
        var pst: c.struct_stat = undefined;
        const pz = pathZ(&z3, parent) catch return fsReplyErr(cl, r.req, "parent path too long");
        if (c.stat(pz, &pst) != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, -1)));
        if (pst.st_dev != tst.st_dev)
            return fsReplyErr(cl, r.req, "hard link would cross filesystems");
        const rc = c.link(tgt, link);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "chmod")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        // chmod FOLLOWS a symlink while the chown beside it uses
        // lchown, so one Apply used to act on two different files --
        // and since a link's own mode is 0777, the client's checkboxes
        // came up fully ticked and set the TARGET world-writable. A
        // link has no permissions of its own to change: refuse.
        var lst: c.struct_stat = undefined;
        if (c.lstat(p, &lst) == 0 and (lst.st_mode & c.S_IFMT) == c.S_IFLNK)
            return fsReplyErr(cl, r.req, "a symbolic link has no permissions of its own");
        const rc = c.chmod(p, @intCast(r.mode & 0o7777));
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "chown")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const uid: c.uid_t = if (r.uid) |v| @intCast(v) else @bitCast(@as(c_int, -1));
        const gid: c.gid_t = if (r.gid) |v| @intCast(v) else @bitCast(@as(c_int, -1));
        const rc = c.lchown(p, uid, gid);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "truncate")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const rc = c.truncate(p, @intCast(r.size));
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "utimens")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        var times = [_]c.struct_timespec{
            millisTimespec(r.atime_ms),
            millisTimespec(r.mtime_ms),
        };
        const rc = c.utimensat(c.AT_FDCWD, p, &times, c.AT_SYMLINK_NOFOLLOW);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "access")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const rc = c.access(p, @intCast(r.mode));
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "fsync")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        // Client-controlled path, refused by kind BEFORE open (see
        // openChecked): a durability barrier means nothing on a device
        // node or FIFO, and opening one is the hazard. Directories stay
        // allowed because fsyncing one IS the barrier after a rename.
        const fd = switch (openChecked(p, c.O_RDONLY, 0, .file_or_dir)) {
            .fd => |fd| fd,
            .refused => |why| return fsReplyErr(cl, r.req, why),
            .failed => |rc| return fsReplyErr(cl, r.req, fsserve.errnoName(rc)),
        };
        defer _ = c.close(fd);
        const rc = c.fsync(fd);
        if (rc != 0) return fsReplyErr(cl, r.req, fsserve.errnoName(rc));
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
    } else if (std.mem.eql(u8, r.op, "statfs")) {
        var z: [4096]u8 = undefined;
        const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
        const st = fsStatvfs(p) orelse return fsReplyErr(cl, r.req, fsserve.errnoName(-1));
        cl.queueJson(.fs_reply, .{
            .req = r.req,
            .ok = true,
            .bsize = st.bsize,
            .frsize = st.frsize,
            .blocks = st.blocks,
            .bfree = st.bfree,
            .bavail = st.bavail,
            .files = st.files,
            .ffree = st.ffree,
            .namemax = st.namemax,
        });
    } else {
        fsReplyErr(cl, r.req, "unknown fs op");
    }
}

pub fn millisTimespec(ms: ?i64) c.struct_timespec {
    const value = ms orelse return .{ .tv_sec = 0, .tv_nsec = c.UTIME_OMIT };
    return .{
        .tv_sec = @divFloor(value, 1000),
        .tv_nsec = @mod(value, 1000) * 1_000_000,
    };
}

/// Resolve the live view a `list` request names, reviving a parked one.
///
/// @return null when nothing usable resolves, so the caller lists
/// `r.path` viewless and a real errno reaches the client as itself
/// rather than as a misleading "no such view".
fn fsViewForRefresh(self: *Daemon, cl: *Client, r: FsOpReq) ?*FsView {
    for (self.fs_views.items) |v| {
        if (v.client != cl or v.id != r.view) continue;
        if (!v.gone) return v;
        return if (fsReviveView(self, v, r.path)) v else null;
    }
    return null;
}

/// Re-establish a `gone` view against `path`, watch included.
///
/// A view whose directory was deleted keeps a dead inotify watch and
/// never speaks again; refusing every later refresh on it made
/// `rm -rf x && mkdir x` unrecoverable without navigating away, when
/// the request itself carries the path to re-open.
/// @return false when `path` is not a directory now.
fn fsReviveView(self: *Daemon, v: *FsView, path: []const u8) bool {
    var z: [4096]u8 = undefined;
    const pz = pathZ(&z, path) catch return false;
    var real_buf: [4096]u8 = undefined;
    const canon: []const u8 = if (c.realpath(pz, &real_buf)) |rp|
        std.mem.span(@as([*:0]const u8, @ptrCast(rp)))
    else
        return false;
    var dst: c.struct_stat = undefined;
    if (c.stat(@as([*:0]const u8, @ptrCast(real_buf[0..canon.len :0])), &dst) != 0 or
        (dst.st_mode & c.S_IFMT) != c.S_IFDIR) return false;
    const path_owned = self.allocator.dupe(u8, canon) catch return false;

    // The old watch died with the old inode; a fresh one on the new
    // directory is what makes deltas resume. dropFsViewAt's sharing
    // rule applies here too (equal paths share one wd).
    if (v.wd >= 0) {
        var shared = false;
        for (self.fs_views.items) |o| {
            if (o != v and o.wd == v.wd) {
                shared = true;
                break;
            }
        }
        if (!shared) self.fs_watch.remove(v.wd);
        v.wd = -1;
    }
    self.allocator.free(v.path);
    v.path = path_owned;
    // The listing about to start is the new baseline, so any deferred
    // burst (including the gone verdict itself) is stale.
    v.boundary.clear(self.allocator);
    v.gone = false;
    if (self.fs_watch.ensure()) {
        var z2: [4096]u8 = undefined;
        const cz = pathZ(&z2, v.path) catch return true;
        const was_full = self.fs_watch.exhausted;
        v.wd = self.fs_watch.add(cz);
        noteWatchExhaustion(self, was_full, v.path);
    }
    return true;
}

/// Log the MOMENT the watch backend runs out, once. `exhausted` is
/// sticky, so comparing it across a single `add` fires on the
/// transition and never again — an out-of-descriptors daemon must not
/// also drown its own log while a client retries.
fn noteWatchExhaustion(self: *Daemon, was_full: bool, path: []const u8) void {
    if (was_full or !self.fs_watch.exhausted) return;
    log.warn("fs watch backend out of capacity at '{s}': views opened from now on list but do not update", .{path});
}

/// True when this view's watch was REFUSED for want of backend
/// capacity: the listing is real, the deltas will never come, and the
/// client has no way to tell that apart from a directory nobody
/// touches. kqueue spends one descriptor per watch and hits
/// EMFILE/ENFILE; inotify spends a max_user_watches slot and hits
/// ENOSPC. `liveScanDir` reports exactly this condition on a query as
/// `watch_limit`; a view owed the same answer and never got it.
///
/// `Watcher.exhausted` is sticky, so a later view that fails to watch
/// for an unrelated reason is attributed to capacity too. That
/// misnames the cause, never the fact: with `wd < 0` the view is not
/// live either way, which is the part the client acts on.
fn fsViewWatchLimited(self: *Daemon, view: ?*FsView) bool {
    const v = view orelse return false;
    return watchLimited(v.wd, self.fs_watch.exhausted);
}

/// The decision alone, so it can be pinned without a live Daemon.
/// A view that HOLDS a watch is live no matter how exhausted the
/// backend became afterwards — reporting those would cry wolf on
/// every view once one refusal made the flag sticky.
fn watchLimited(wd: c_int, backend_exhausted: bool) bool {
    return wd < 0 and backend_exhausted;
}

test "a view is watch-limited only when it holds no watch AND the backend refused" {
    const t = std.testing;
    // No watch, backend out of capacity: the listing is real, the
    // deltas never come — the one case the client must be told about.
    try t.expect(watchLimited(-1, true));
    // Holds a watch: live, even though `exhausted` is sticky and some
    // OTHER view was refused earlier.
    try t.expect(!watchLimited(3, true));
    try t.expect(!watchLimited(0, true));
    // No watch, backend never refused (no watcher backend at all, or a
    // path-specific failure): not a capacity story, so not this flag.
    try t.expect(!watchLimited(-1, false));
    try t.expect(!watchLimited(3, false));
}

pub fn fsOpenView(self: *Daemon, cl: *Client, r: FsOpReq) void {
    for (self.fs_views.items) |v| {
        if (v.client == cl and v.id == r.view) return fsReplyErr(cl, r.req, "view id in use");
    }
    // Canonicalize so delta paths and the reported root agree.
    var z: [4096]u8 = undefined;
    const pz = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
    var real_buf: [4096]u8 = undefined;
    const canon: []const u8 = if (c.realpath(pz, &real_buf)) |rp|
        std.mem.span(@as([*:0]const u8, @ptrCast(rp)))
    else
        return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, -1)));
    var dst: c.struct_stat = undefined;
    if (c.stat(@as([*:0]const u8, @ptrCast(real_buf[0..canon.len :0])), &dst) != 0 or
        (dst.st_mode & c.S_IFMT) != c.S_IFDIR)
        return fsReplyErr(cl, r.req, "not a directory");

    // Watch BEFORE listing: changes racing the listing surface as
    // deltas after it (upserts are idempotent), never fall in a gap.
    var wd: c_int = -1;
    if (self.fs_watch.ensure()) {
        var z2: [4096]u8 = undefined;
        const cz = pathZ(&z2, canon) catch return fsReplyErr(cl, r.req, "path too long");
        const was_full = self.fs_watch.exhausted;
        wd = self.fs_watch.add(cz);
        noteWatchExhaustion(self, was_full, canon);
    }
    const view = self.allocator.create(FsView) catch return fsReplyErr(cl, r.req, "out of memory");
    const path_owned = self.allocator.dupe(u8, canon) catch {
        self.allocator.destroy(view);
        return fsReplyErr(cl, r.req, "out of memory");
    };
    const attrs_owned = self.allocator.dupe(u8, r.attrs) catch {
        self.allocator.free(path_owned);
        self.allocator.destroy(view);
        return fsReplyErr(cl, r.req, "out of memory");
    };
    view.* = .{
        .allocator = self.allocator,
        .client = cl,
        .id = r.view,
        .path = path_owned,
        .wd = wd,
        .attrs = attrs_owned,
    };
    self.fs_views.append(self.allocator, view) catch {
        view.deinit();
        return fsReplyErr(cl, r.req, "out of memory");
    };
    // Listing failure (dir vanished between checks) → the open as
    // a whole failed; the view must not linger daemon-side.
    if (!fsStartListing(self, cl, r.req, canon, r.attrs, view))
        dropFsViewAt(self, self.fs_views.items.len - 1);
}

/// Report — and optionally raise the system prompt for — this
/// daemon's Screen Recording grant.
///
/// The GUI cannot answer this itself: `sketerm` and `sketerm-mux` are
/// separate binaries with separate TCC identities, and the capture
/// happens here. Preflighting in the GUI would report the wrong
/// process's permission, which is worse than reporting none.
///
/// `supported=false` off macOS (and on a build without the SCK
/// backend), so the welcome dialog can hide the step entirely rather
/// than show a control that cannot mean anything.
///
/// Note `granted` cannot distinguish "never asked" from "denied" —
/// `CGPreflightScreenCaptureAccess` returns false for both and no
/// public API separates them. The reply says what is true and the UI
/// offers both routes rather than guessing.
fn screenPerm(cl: *Client, r: FsOpReq, do_request: bool) void {
    const wssource = @import("../winstream/source.zig");
    if (comptime !wssource.have_sck) {
        cl.queueJson(.fs_reply, .{
            .req = r.req,
            .ok = true,
            .supported = false,
            .granted = false,
            .adhoc = false,
            .identity_known = false,
        });
        return;
    }
    const sck = @import("../winstream/sck.zig");
    // Requesting BEFORE reading back is deliberate: a first-ever
    // request can be answered by the user while the prompt is up, and
    // reporting the pre-prompt value would look like the click did
    // nothing. It usually still reads false here — TCC applies the
    // grant to the next launch — which is why the dialog tells the
    // user a daemon restart is what makes it live.
    if (do_request) sck.permissionRequest();
    const adhoc = sck.permissionIdentityAdhoc();
    cl.queueJson(.fs_reply, .{
        .req = r.req,
        .ok = true,
        .supported = true,
        .granted = sck.permissionGranted(),
        .adhoc = adhoc orelse false,
        .identity_known = adhoc != null,
        .exe = daemonExePath(),
    });
}

/// This daemon's own executable path, so the dialog can name the
/// binary the user must find in System Settings — with two daemons
/// installed (a dev build and a signed one) the name alone is
/// ambiguous, and picking the wrong row grants nothing.
fn daemonExePath() []const u8 {
    const S = struct {
        var buf: [4096]u8 = undefined;
    };
    return platform.exePath(&S.buf) orelse "sketerm-mux";
}

pub fn fsCloseView(self: *Daemon, cl: *Client, r: FsOpReq) void {
    var i: usize = 0;
    while (i < self.fs_views.items.len) : (i += 1) {
        const v = self.fs_views.items[i];
        if (v.client == cl and v.id == r.view) {
            dropFsViewAt(self, i);
            cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true });
            return;
        }
    }
    fsReplyErr(cl, r.req, "no such view");
}

/// Remove fs_views[i]; the kernel watch goes only when no other
/// view shares its wd (inotify hands equal paths the same wd).
pub fn dropFsViewAt(self: *Daemon, i: usize) void {
    const v = self.fs_views.swapRemove(i);
    // A dying view aborts its in-flight listing outright. Statting on
    // for a view nobody watches would queue chunks AHEAD of whatever
    // the client asks for next — on a slow link that backlog is why
    // a navigation away from a huge folder went dead. Every
    // close_view is preceded by cancelPendingDir client-side, so the
    // terminator frame can never land on a live accumulator.
    var j: usize = 0;
    while (j < self.fs_listings.items.len) {
        const l = self.fs_listings.items[j];
        if (l.client == v.client and l.view == v) {
            if (l.stage == .stat) {
                l.client.queueJson(.fs_reply, .{
                    .req = l.req,
                    .ok = true,
                    .path = l.path,
                    .entries = &[_]fsserve.Entry{},
                    .more = false,
                    .aborted = true,
                });
            }
            l.boundary_open = false;
            l.view = null;
            _ = self.fs_listings.swapRemove(j);
            l.deinit();
        } else j += 1;
    }
    if (v.wd >= 0) {
        var shared = false;
        for (self.fs_views.items) |o| {
            if (o.wd == v.wd) {
                shared = true;
                break;
            }
        }
        if (!shared) self.fs_watch.remove(v.wd);
    }
    v.deinit();
}

/// Cap on how many attributes one listing may carry per entry:
/// each name costs an lgetxattr per entry, so the column set is
/// bounded rather than trusted.
const MAX_ATTR_NAMES = 8;

/// Split a comma-separated attribute request into `buf`, keeping
/// only `user.`-namespaced names.
pub fn splitAttrs(spec: []const u8, buf: *[MAX_ATTR_NAMES][]const u8) []const []const u8 {
    if (spec.len == 0) return &.{};
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |raw| {
        if (n >= buf.len) break;
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0 or !std.mem.startsWith(u8, name, "user.")) continue;
        buf[n] = name;
        n += 1;
    }
    return buf[0..n];
}

/// Per-batch bounds for pumpFsListings: a chunk frame never carries
/// more than CHUNK_ENTRIES entries, and a batch stops early once its
/// time box elapses — one slow filesystem (NFS, cold disk) then costs
/// small chunks, never a stalled poll loop.
const LISTING_BATCH_MS: i64 = 8;
const COUNT_BATCH_MS: i64 = 5;
/// Skip a listing while its client's write buffer is over this mark;
/// POLLOUT drains it and the pump resumes (pumpDownloads' rule).
/// Deliberately far below the download watermark: everything the
/// client asks for NEXT queues behind these bytes, and on a slow
/// remote link a megabyte of backlog is already seconds of dead UI.
const LISTING_WATERMARK: usize = 1 << 20;

/// Begin an incremental listing. The names are read and sorted NOW —
/// one cheap readdir pass, so open failures still reply synchronously
/// and fsOpenView's drop-the-view-on-failure contract holds — then
/// the per-entry stats stream from pumpFsListings as the fs_reply
/// chunk run (`more:true` until the last) every client already
/// accumulates. `view` non-null schedules async child counts after
/// the listing, delivered as upsert deltas on that view.
pub fn fsStartListing(self: *Daemon, cl: *Client, req: u32, dir_path: []const u8, attr_spec: []const u8, view: ?*FsView) bool {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    // The REASON travels: "cannot open directory" made a permission
    // denial and a vanished directory indistinguishable, and a
    // client cannot report what it was never told.
    var why: []const u8 = "";
    const names = fsserve.readNames(arena_state.allocator(), dir_path, fsserve.MAX_ENTRIES, &why) catch {
        arena_state.deinit();
        fsReplyErr(cl, req, if (why.len > 0) why else "cannot open directory");
        return false;
    };

    // The directory's device id rides the listing (one number, not
    // per entry): it is what lets a client decide BEFORE offering
    // the verb whether a hard link into this directory could work.
    var dir_st: c.struct_stat = undefined;
    var z: [4096]u8 = undefined;
    const dev: u64 = if (pathZ(&z, dir_path)) |dz|
        (if (c.stat(dz, &dir_st) == 0) @intCast(dir_st.st_dev) else 0)
    else |_|
        0;

    const listing = self.allocator.create(dmod.FsListing) catch {
        arena_state.deinit();
        fsReplyErr(cl, req, "out of memory");
        return false;
    };
    const path_owned = self.allocator.dupe(u8, dir_path) catch {
        self.allocator.destroy(listing);
        arena_state.deinit();
        fsReplyErr(cl, req, "out of memory");
        return false;
    };
    const attrs_owned = self.allocator.dupe(u8, attr_spec) catch {
        self.allocator.free(path_owned);
        self.allocator.destroy(listing);
        arena_state.deinit();
        fsReplyErr(cl, req, "out of memory");
        return false;
    };
    listing.* = .{
        .allocator = self.allocator,
        .arena = arena_state,
        .client = cl,
        .req = req,
        .path = path_owned,
        .attrs = attrs_owned,
        .names = names.names,
        .truncated = names.truncated,
        .dev = dev,
        .view = view,
    };
    self.fs_listings.append(self.allocator, listing) catch {
        listing.deinit();
        fsReplyErr(cl, req, "out of memory");
        return false;
    };
    if (view) |v| {
        v.boundary.begin();
        listing.boundary_open = true;
    }
    // First batch immediately: a small local directory completes in
    // this very call, keeping the old one-round-trip latency.
    if (pumpListing(self, listing)) {
        _ = self.fs_listings.pop();
        listing.deinit();
    }
    return true;
}

/// Advance every in-flight listing by one bounded batch (tick).
pub fn pumpFsListings(self: *Daemon) void {
    var i: usize = 0;
    while (i < self.fs_listings.items.len) {
        const listing = self.fs_listings.items[i];
        if (pumpListing(self, listing)) {
            _ = self.fs_listings.swapRemove(i);
            listing.deinit();
        } else i += 1;
    }
}

/// One batch of one listing. True = finished (caller removes it).
fn pumpListing(self: *Daemon, listing: *dmod.FsListing) bool {
    if (listing.client.dead) {
        closeListingBoundary(self, listing, false);
        return true;
    }
    if (listing.client.queuedBytes() >= LISTING_WATERMARK) return false;
    const a = listing.arena.allocator();
    switch (listing.stage) {
        .stat => {
            var attr_buf: [MAX_ATTR_NAMES][]const u8 = undefined;
            const attrs = splitAttrs(listing.attrs, &attr_buf);
            var chunk: std.ArrayList(fsserve.Entry) = .empty;
            const deadline = nowMs() + LISTING_BATCH_MS;
            while (listing.idx < listing.names.len and chunk.items.len < fsserve.CHUNK_ENTRIES) {
                const name = listing.names[listing.idx];
                listing.idx += 1;
                if (fsserve.statEntryAttrs(a, listing.path, name, attrs, false)) |e| {
                    chunk.append(a, e) catch break;
                    if (listing.view != null and e.tdir) listing.dirs.append(a, e) catch {};
                }
                if (nowMs() >= deadline) break;
            }
            const last = listing.idx == listing.names.len;
            // An empty non-final batch (every stat in the box was a
            // vanished entry, or one stat ate the whole box) sends
            // nothing — the run is still open, the next tick continues.
            if (chunk.items.len > 0 or last) {
                listing.client.queueJson(.fs_reply, .{
                    .req = listing.req,
                    .ok = true,
                    .path = listing.path,
                    .dev = listing.dev,
                    .entries = chunk.items,
                    .more = !last,
                    .truncated = listing.truncated,
                    .watch_limit = fsViewWatchLimited(self, listing.view),
                });
            }
            if (!last) return false;
            closeListingBoundary(self, listing, true);
            if (listing.view == null or listing.dirs.items.len == 0) return true;
            listing.stage = .count;
            return false;
        },
        .count => {
            const view = listing.view orelse return true;
            if (view.gone) return true;
            // Another refresh snapshot for this view is still open.
            // Count upserts are deltas too, so they wait behind it.
            if (view.boundary.active > 0) return false;
            var changes: std.ArrayList(FsChange) = .empty;
            const deadline = nowMs() + COUNT_BATCH_MS;
            var attr_buf: [MAX_ATTR_NAMES][]const u8 = undefined;
            const attrs = splitAttrs(listing.attrs, &attr_buf);
            while (listing.count_idx < listing.dirs.items.len) {
                const e = &listing.dirs.items[listing.count_idx];
                listing.count_idx += 1;
                var z: [4096]u8 = undefined;
                if (fsserve.joinZ(&z, listing.path, e.name)) |full| {
                    const cnt = fsserve.countChildren(full);
                    // Vanished or over the cap: leave it unknown
                    // rather than upsert a stale entry back to life.
                    if (cnt >= 0) {
                        // The entry may have changed while snapshots
                        // streamed. Re-stat so a late count cannot
                        // overwrite a newer watch delta with old metadata.
                        if (fsserve.statEntryAttrs(a, listing.path, e.name, attrs, true)) |fresh| {
                            var counted = fresh;
                            counted.children = if (counted.tdir) cnt else -1;
                            changes.append(a, .{ .op = "upsert", .name = counted.name, .entry = counted }) catch break;
                        }
                    }
                } else |_| {}
                if (nowMs() >= deadline) break;
            }
            if (changes.items.len > 0)
                listing.client.queueJson(.fs_delta, .{ .view = view.id, .changes = changes.items });
            return listing.count_idx == listing.dirs.items.len;
        },
    }
}

fn closeListingBoundary(self: *Daemon, listing: *dmod.FsListing, flush: bool) void {
    if (!listing.boundary_open) return;
    listing.boundary_open = false;
    const view = listing.view orelse return;
    if (!view.boundary.finish()) return;
    if (flush) {
        flushFsViewBoundary(view);
    } else {
        view.boundary.clear(self.allocator);
    }
}

/// Emit the current state of every name touched while snapshots were active.
fn flushFsViewBoundary(view: *FsView) void {
    const allocator = view.allocator;
    defer view.boundary.clear(allocator);
    if (view.boundary.gone) {
        view.gone = true;
        view.client.queueJson(.fs_delta, .{
            .view = view.id,
            .gone = true,
            .changes = &[_]FsChange{},
        });
        return;
    }
    if (view.boundary.resync) {
        view.client.queueJson(.fs_delta, .{
            .view = view.id,
            .resync = true,
            .changes = &[_]FsChange{},
        });
        return;
    }
    if (view.boundary.names.items.len == 0) return;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var changes: std.ArrayList(FsChange) = .empty;
    var attr_buf: [MAX_ATTR_NAMES][]const u8 = undefined;
    const attrs = splitAttrs(view.attrs, &attr_buf);
    for (view.boundary.names.items) |name| {
        if (fsserve.statEntryAttrs(arena, view.path, name, attrs, true)) |entry| {
            changes.append(arena, .{ .op = "upsert", .name = entry.name, .entry = entry }) catch {
                view.client.queueJson(.fs_delta, .{ .view = view.id, .resync = true, .changes = &[_]FsChange{} });
                return;
            };
        } else {
            changes.append(arena, .{ .op = "del", .name = name }) catch {
                view.client.queueJson(.fs_delta, .{ .view = view.id, .resync = true, .changes = &[_]FsChange{} });
                return;
            };
        }
    }
    if (changes.items.len > 0)
        view.client.queueJson(.fs_delta, .{ .view = view.id, .changes = changes.items });
}

pub fn fsStat(self: *Daemon, cl: *Client, r: FsOpReq) void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const dir = std.fs.path.dirname(r.path) orelse "/";
    const base = std.fs.path.basename(r.path);
    if (base.len == 0) {
        // Stat of "/" itself.
        const e = fsserve.statEntry(arena_state.allocator(), "/", ".") orelse
            return fsReplyErr(cl, r.req, "stat failed");
        cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true, .entry = e });
        return;
    }
    const e = fsserve.statEntry(arena_state.allocator(), dir, base) orelse
        return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, -1)));
    cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true, .entry = e });
}

/// Bounded ranged read: fs_data [u32 req][u64 off][bytes], then a
/// closing fs_reply { size, eof }. Clients loop for large files —
/// one request can never queue more than MAX_READ toward a client.
pub fn fsRead(self: *Daemon, cl: *Client, r: FsOpReq) void {
    var z: [4096]u8 = undefined;
    const p = pathZ(&z, r.path) catch return fsReplyErr(cl, r.req, "path too long");
    // Remote-controlled path, refused by kind before open (openChecked).
    const fd = switch (openChecked(p, c.O_RDONLY, 0, .file)) {
        .fd => |fd| fd,
        .refused => |why| return fsReplyErr(cl, r.req, why),
        .failed => |rc| return fsReplyErr(cl, r.req, fsserve.errnoName(rc)),
    };
    defer _ = c.close(fd);
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) return fsReplyErr(cl, r.req, "fstat failed");
    const size: u64 = if (st.st_size > 0) @intCast(st.st_size) else 0;

    const want: usize = @min(@as(usize, r.len), fsserve.MAX_READ);
    const buf = self.allocator.alloc(u8, 12 + want) catch
        return fsReplyErr(cl, r.req, "out of memory");
    defer self.allocator.free(buf);
    std.mem.writeInt(u32, buf[0..4], r.req, .little);
    std.mem.writeInt(u64, buf[4..12], r.off, .little);
    var got: usize = 0;
    while (got < want) {
        const n = c.pread(fd, buf.ptr + 12 + got, want - got, @intCast(r.off + got));
        if (n < 0) return fsReplyErr(cl, r.req, fsserve.errnoName(@as(c_int, @intCast(n))));
        if (n == 0) break;
        got += @intCast(n);
    }
    // Deliberately NO second stat: a file growing under the reader (a live
    // log is the common case) must still answer with the bytes that were
    // read. Callers that need one identity across a MULTI-range read compare
    // the mtime/ino below themselves — panel asset hydration does exactly
    // that in Terminal.handleRemoteFileReply.
    cl.queueFrame(.fs_data, buf[0 .. 12 + got]);
    if (std.mem.startsWith(u8, r.path, fsjob.SPOOL_PREFIX)) daemon_fsjobs.spoolNoteRead(self, r.path, r.off + got);
    cl.queueJson(.fs_reply, .{
        .req = r.req,
        .ok = true,
        .size = size,
        .eof = r.off + got >= size,
        // Identity of the bytes just handed out, taken from the SAME
        // fd they were read through: an editor that stats separately
        // races a writer between the two calls.
        .mtime_ns = fsserve.mtimeNs(&st),
        .ino = @as(u64, @intCast(st.st_ino)),
    });
}

/// Fresh single-path stat as a wire Entry, for replies that hand the
/// client its next baseline. Null when the path cannot be stat'ed.
fn entryAt(arena: std.mem.Allocator, path: []const u8) ?fsserve.Entry {
    const base = std.fs.path.basename(path);
    if (base.len == 0) return fsserve.statEntry(arena, "/", ".");
    return fsserve.statEntry(arena, std.fs.path.dirname(path) orelse "/", base);
}

/// Atomic save: install the staged regular file `path` over `to`.
///
/// The destination's permission bits and ownership are inherited (a
/// save must not turn a 0755 script into a 0644 one), the staged file
/// is fsynced before the rename and the destination's parent
/// directory after it, and a destination whose mtime_ns no longer
/// matches `expected_mtime_ns` is refused as `conflict` with a fresh
/// entry so the caller can show the external change. Every failure
/// after the staged-file check leaves the temp in place — the caller
/// owns it and cleans up.
pub fn fsInstall(self: *Daemon, cl: *Client, r: FsOpReq) void {
    if (r.to.len == 0 or r.to[0] != '/') return fsReplyErr(cl, r.req, "to must be absolute");
    var z1: [4096]u8 = undefined;
    var z2: [4096]u8 = undefined;
    const tmp = pathZ(&z1, r.path) catch return fsReplyErr(cl, r.req, "staged path too long");
    const dest = pathZ(&z2, r.to) catch return fsReplyErr(cl, r.req, "destination path too long");

    var tst: c.struct_stat = undefined;
    if (c.lstat(tmp, &tst) != 0) return fsReplyErr(cl, r.req, "staged file missing");
    if ((tst.st_mode & c.S_IFMT) != c.S_IFREG)
        return fsReplyErr(cl, r.req, "staged path is not a regular file");

    var dst: c.struct_stat = undefined;
    const dest_exists = c.stat(dest, &dst) == 0;
    if (dest_exists) {
        if (r.expected_mtime_ns) |want| {
            if (fsserve.mtimeNs(&dst) != want) {
                var arena_state = std.heap.ArenaAllocator.init(self.allocator);
                defer arena_state.deinit();
                cl.queueJson(.fs_reply, .{
                    .req = r.req,
                    .ok = false,
                    .@"error" = "conflict",
                    .entry = entryAt(arena_state.allocator(), r.to),
                });
                return;
            }
        }
    }

    // One fd serves both the metadata inheritance and the durability
    // barrier; fchmod/fchown need ownership, not write access.
    const fd = c.open(tmp, c.O_RDONLY | c.O_CLOEXEC);
    if (fd < 0) return fsReplyErr(cl, r.req, "cannot open staged file");
    if (dest_exists) {
        _ = c.fchmod(fd, @intCast(dst.st_mode & 0o7777));
        // EPERM is the normal answer for an unprivileged daemon; a
        // save must not fail because it could not also move owners.
        _ = c.fchown(fd, dst.st_uid, dst.st_gid);
    }
    const sync_rc = c.fsync(fd);
    _ = c.close(fd);
    if (sync_rc != 0) return fsReplyErr(cl, r.req, "cannot fsync staged file");

    const rc = c.rename(tmp, dest);
    if (rc != 0) {
        var msg: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&msg, "install rename failed: {s}", .{
            fsserve.errnoName(rc),
        }) catch "install rename failed";
        return fsReplyErr(cl, r.req, text);
    }

    const parent = std.fs.path.dirname(r.to) orelse return fsReplyErr(cl, r.req, "destination has no parent");
    var dz: [4096]u8 = undefined;
    const dfd = c.open(
        pathZ(&dz, parent) catch return fsReplyErr(cl, r.req, "destination parent path too long"),
        c.O_RDONLY | c.O_DIRECTORY,
    );
    if (dfd < 0) return fsReplyErr(cl, r.req, "cannot open destination parent");
    defer _ = c.close(dfd);
    if (c.fsync(dfd) != 0) return fsReplyErr(cl, r.req, "cannot fsync destination parent");

    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const e = entryAt(arena_state.allocator(), r.to) orelse
        return fsReplyErr(cl, r.req, "installed but stat failed");
    cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true, .entry = e });
}

pub const AppEntry = struct {
    name: []const u8,
    exec: []const u8,
    mimes: []const u8,
};

/// Enumerate this host's launchable .desktop applications in one
/// reply, so a remote "Open With" costs one round trip instead of
/// one per .desktop file. Bounded: MAX_APPS entries, 8KB/file.
pub fn fsApps(self: *Daemon, cl: *Client, r: FsOpReq) void {
    const MAX_APPS = 400;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var apps: std.ArrayList(AppEntry) = .empty;

    var home_buf: [4096]u8 = undefined;
    const home_apps: ?[]const u8 = if (c.getenv("HOME")) |h|
        std.fmt.bufPrint(&home_buf, "{s}/.local/share/applications", .{
            std.mem.span(@as([*:0]const u8, @ptrCast(h))),
        }) catch null
    else
        null;
    const dirs = [_]?[]const u8{
        home_apps,
        "/usr/local/share/applications",
        "/usr/share/applications",
    };
    for (dirs) |maybe_dir| {
        const dir_path = maybe_dir orelse continue;
        var dz: [4096]u8 = undefined;
        const dp = pathZ(&dz, dir_path) catch continue;
        const d = c.opendir(dp) orelse continue;
        defer _ = c.closedir(d);
        while (c.readdir(d)) |de| {
            if (apps.items.len >= MAX_APPS) break;
            const fname = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
            if (!std.mem.endsWith(u8, fname, ".desktop")) continue;
            var fz: [4400:0]u8 = undefined;
            const fp = std.fmt.bufPrintZ(&fz, "{s}/{s}", .{ dir_path, fname }) catch continue;
            const f = c.fopen(fp.ptr, "rb") orelse continue;
            var content: [8192]u8 = undefined;
            const n = c.fread(&content, 1, content.len, f);
            _ = c.fclose(f);
            var name: []const u8 = "";
            var exec: []const u8 = "";
            var mimes: []const u8 = "";
            var is_app = false;
            var hidden = false;
            var in_entry = false;
            var it = std.mem.tokenizeScalar(u8, content[0..n], '\n');
            while (it.next()) |line_raw| {
                const line = std.mem.trim(u8, line_raw, " \t\r");
                if (line.len > 0 and line[0] == '[') {
                    in_entry = std.mem.eql(u8, line, "[Desktop Entry]");
                    continue;
                }
                if (!in_entry) continue;
                if (std.mem.startsWith(u8, line, "Name=") and name.len == 0) name = line[5..];
                if (std.mem.startsWith(u8, line, "Exec=") and exec.len == 0) exec = line[5..];
                if (std.mem.startsWith(u8, line, "MimeType=")) mimes = line[9..];
                if (std.mem.startsWith(u8, line, "Type=")) is_app = std.mem.eql(u8, line[5..], "Application");
                if (std.mem.startsWith(u8, line, "NoDisplay=") or std.mem.startsWith(u8, line, "Hidden=")) {
                    const v = line[std.mem.indexOfScalar(u8, line, '=').? + 1 ..];
                    if (std.mem.eql(u8, v, "true")) hidden = true;
                }
            }
            if (!is_app or hidden or name.len == 0 or exec.len == 0) continue;
            // User-dir entries shadow system ones of the same name.
            const dup = for (apps.items) |a| {
                if (std.mem.eql(u8, a.name, name)) break true;
            } else false;
            if (dup) continue;
            apps.append(arena, .{
                .name = arena.dupe(u8, name) catch continue,
                .exec = arena.dupe(u8, exec) catch continue,
                .mimes = arena.dupe(u8, mimes) catch continue,
            }) catch break;
        }
    }
    cl.queueJson(.fs_reply, .{ .req = r.req, .ok = true, .apps = apps.items });
}

/// fs_write payload: [u32 req][u64 off][u8 flags][u16 path_len]
/// [path][data]. flags bit0=create bit1=truncate bit2=append
/// bit3=exclusive.
pub fn handleFsWrite(self: *Daemon, cl: *Client, payload: []const u8) void {
    _ = self;
    if (payload.len < 15) {
        cl.queueErr("bad fs_write");
        return;
    }
    const req = std.mem.readInt(u32, payload[0..4], .little);
    const off = std.mem.readInt(u64, payload[4..12], .little);
    const flags = payload[12];
    const plen = std.mem.readInt(u16, payload[13..15], .little);
    if (payload.len < 15 + @as(usize, plen)) return fsReplyErr(cl, req, "bad fs_write");
    const path = payload[15 .. 15 + plen];
    const data = payload[15 + plen ..];
    if (path.len == 0 or path[0] != '/') return fsReplyErr(cl, req, "path must be absolute");

    // Client-controlled path, refused by kind BEFORE open (see openChecked):
    // an existing device node or FIFO never gets the daemon's open, let
    // alone its writes. O_CREAT makes a regular file, so a path stat
    // cannot see is created and then held to the post-open check. The
    // O_NONBLOCK openChecked adds cannot reach the write loop as a
    // spurious EAGAIN: only regular files survive the kind check, and
    // the flag has no effect on their read/write.
    var oflags: c_int = c.O_WRONLY;
    if (flags & 1 != 0) oflags |= c.O_CREAT;
    if (flags & 2 != 0) oflags |= c.O_TRUNC;
    if (flags & 4 != 0) oflags |= c.O_APPEND;
    if (flags & 8 != 0) oflags |= c.O_EXCL;
    var z: [4096]u8 = undefined;
    const p = pathZ(&z, path) catch return fsReplyErr(cl, req, "path too long");
    const fd = switch (openChecked(p, oflags, @as(c.mode_t, 0o644), .file)) {
        .fd => |fd| fd,
        .refused => |why| return fsReplyErr(cl, req, why),
        .failed => |rc| return fsReplyErr(cl, req, fsserve.errnoName(rc)),
    };
    defer _ = c.close(fd);

    var written: usize = 0;
    while (written < data.len) {
        const n = if (flags & 4 != 0)
            c.write(fd, data.ptr + written, data.len - written)
        else
            c.pwrite(fd, data.ptr + written, data.len - written, @intCast(off + written));
        if (n <= 0) return fsReplyErr(cl, req, fsserve.errnoName(@as(c_int, @intCast(n))));
        written += @intCast(n);
    }
    cl.queueJson(.fs_reply, .{ .req = req, .ok = true, .written = written });
}

/// Drain the shared inotify fd and push coalesced fs_delta frames.
/// Per view per drain: at most one delta frame, changes deduped by
/// name (last state wins — a create+delete burst nets out to what
/// a fresh stat says). Kernel queue overflow degrades honestly to
/// `resync:true` (the client must re-list; deltas alone are no
/// longer trustworthy).
pub fn fsWatchReadable(self: *Daemon) void {
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const PerView = struct {
        view: *FsView,
        changes: std.ArrayList(FsChange) = .empty,
        gone: bool = false,
        resync: bool = false,
    };
    var touched: std.ArrayList(*PerView) = .empty;

    const findOrAdd = struct {
        fn go(a: std.mem.Allocator, list: *std.ArrayList(*PerView), v: *FsView) ?*PerView {
            for (list.items) |pv| {
                if (pv.view == v) return pv;
            }
            const pv = a.create(PerView) catch return null;
            pv.* = .{ .view = v };
            list.append(a, pv) catch return null;
            return pv;
        }
    }.go;

    var buf: [16 * 1024]u8 = undefined;
    var overflow = false;
    while (true) {
        const n = self.fs_watch.readInto(&buf);
        if (n <= 0) break; // EAGAIN → drained
        var it = fsserve.EventIter{ .buf = buf[0..@intCast(n)] };
        while (it.next()) |ev| {
            if (ev.isOverflow()) {
                overflow = true;
                continue;
            }
            for (self.fs_views.items) |v| {
                if (v.wd != ev.wd or v.gone) continue;
                const pv = findOrAdd(arena, &touched, v) orelse continue;
                if (ev.isSelfGone()) {
                    pv.gone = true;
                    continue;
                }
                if (ev.name.len == 0) continue;
                // Last state wins: drop any earlier change for this
                // name, then append the current verdict.
                var i: usize = 0;
                while (i < pv.changes.items.len) {
                    if (std.mem.eql(u8, pv.changes.items[i].name, ev.name)) {
                        _ = pv.changes.swapRemove(i);
                    } else i += 1;
                }
                // A rename target may exist even when the event says
                // MOVED_FROM (rapid re-create) — trust a fresh stat
                // over the event kind.
                var attr_buf: [MAX_ATTR_NAMES][]const u8 = undefined;
                if (fsserve.statEntryAttrs(arena, v.path, ev.name, splitAttrs(v.attrs, &attr_buf), true)) |e| {
                    pv.changes.append(arena, .{ .op = "upsert", .name = e.name, .entry = e }) catch {};
                } else {
                    // Stat failed → the entry is gone now, whatever
                    // the event kind said (create+delete bursts).
                    const name_owned = arena.dupe(u8, ev.name) catch continue;
                    pv.changes.append(arena, .{ .op = "del", .name = name_owned }) catch {};
                }
            }
        }
    }

    if (overflow) {
        for (self.fs_views.items) |v| {
            if (v.gone) continue;
            const pv = findOrAdd(arena, &touched, v) orelse continue;
            pv.resync = true;
        }
    }

    for (touched.items) |pv| {
        // A streamed snapshot is an older baseline. Keep every watch
        // verdict behind all overlapping snapshots for this view;
        // flushFsViewBoundary re-stats the bounded name set after the
        // matching final reply has been queued.
        if (pv.view.boundary.active > 0) {
            if (pv.gone) {
                pv.view.boundary.markGone(self.allocator);
            } else if (pv.resync) {
                pv.view.boundary.markResync(self.allocator);
            } else {
                for (pv.changes.items) |change|
                    pv.view.boundary.deferName(self.allocator, change.name);
            }
        } else if (pv.gone) {
            pv.view.gone = true;
            pv.view.client.queueJson(.fs_delta, .{
                .view = pv.view.id,
                .gone = true,
                .changes = &[_]FsChange{},
            });
        } else if (pv.resync) {
            pv.view.client.queueJson(.fs_delta, .{
                .view = pv.view.id,
                .resync = true,
                .changes = &[_]FsChange{},
            });
        } else if (pv.changes.items.len > 0) {
            pv.view.client.queueJson(.fs_delta, .{
                .view = pv.view.id,
                .changes = pv.changes.items,
            });
        }
    }
}
