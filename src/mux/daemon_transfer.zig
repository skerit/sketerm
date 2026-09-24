//! File uploads (`file_open` / `file_data` / `file_close`) into the
//! attached session's cwd and downloads (`file_get` + reverse
//! `file_data`), one in-flight table each per client. Split out of
//! daemon_serve.zig; functions take the owning *Daemon and are aliased
//! back into Daemon.

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

const daemon_fsops = @import("daemon_fsops.zig");
const openChecked = daemon_fsops.openChecked;

// === File upload (file_* frames) ===========================
// The GUI streams a local file to the daemon, which writes it into
// the session shell's working directory — so "drag a file onto a
// remote pane" lands it on the remote box, over any transport.

/// Most concurrent uploads a single client may have open. Bounds
/// the open-fd + partial-file footprint of a misbehaving client.
const max_uploads_per_client = 8;

pub fn findUpload(self: *Daemon, cl: *Client, xfer: u32) ?*Upload {
    for (self.uploads.items) |u| {
        if (u.client == cl and u.xfer == xfer) return u;
    }
    return null;
}

pub fn fileReply(cl: *Client, xfer: u32, status: []const u8, written: u64, path: []const u8, message: []const u8) void {
    cl.queueJson(.file_reply, .{
        .xfer = xfer,
        .status = status,
        .written = written,
        .path = path,
        .message = message,
    });
}

/// Remove an upload from the list and free it. `unlink_partial`
/// removes the on-disk file too (used on a write error — the
/// half-written file we created is ours to clean up).
pub fn dropUpload(self: *Daemon, up: *Upload, unlink_partial: bool) void {
    if (unlink_partial) {
        var z: [4096]u8 = undefined;
        if (pathZ(&z, up.path)) |p| {
            _ = c.unlink(p);
        } else |_| {}
    }
    for (self.uploads.items, 0..) |item, i| {
        if (item == up) {
            _ = self.uploads.swapRemove(i);
            break;
        }
    }
    up.deinit();
}

/// The last path component of `name`, with any directory part
/// stripped — a client can't write outside the session cwd.
pub fn uploadBaseName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| return name[slash + 1 ..];
    return name;
}

/// Open a fresh file named `base` in `cwd`, never clobbering an
/// existing one: on a name collision, insert " (N)" before the
/// extension ("notes.txt" → "notes (1).txt"). Writes the chosen
/// absolute path into `out` and returns it plus the open fd.
pub fn openUploadDest(cwd: []const u8, base: []const u8, out: *[4096]u8) !struct { fd: c_int, path: []const u8 } {
    // Split "stem.ext" so the suffix lands before the extension.
    const dot = std.mem.lastIndexOfScalar(u8, base, '.');
    const stem = if (dot) |d| (if (d == 0) base else base[0..d]) else base;
    const ext = if (dot) |d| (if (d == 0) "" else base[d..]) else "";

    var n: u32 = 0;
    while (n < 1000) : (n += 1) {
        const path = if (n == 0)
            std.fmt.bufPrintZ(out, "{s}/{s}", .{ cwd, base }) catch return error.NameTooLong
        else
            std.fmt.bufPrintZ(out, "{s}/{s} ({d}){s}", .{ cwd, stem, n, ext }) catch return error.NameTooLong;
        // O_CLOEXEC: an upload fd lives across poll-loop ticks while the
        // daemon forks and execs children (PTY spawns, display keepers).
        const fd = c.open(path.ptr, c.O_WRONLY | c.O_CREAT | c.O_EXCL | c.O_CLOEXEC, @as(c_uint, 0o644));
        if (fd >= 0) return .{ .fd = fd, .path = path };
        if (std.posix.errno(fd) != .EXIST) return error.OpenFailed;
    }
    return error.OpenFailed;
}

test "an upload lands under its base name and never clobbers an existing file" {
    const t = std.testing;
    try t.expectEqualStrings("notes.txt", uploadBaseName("/home/u/docs/notes.txt"));
    try t.expectEqualStrings("notes.txt", uploadBaseName("notes.txt"));
    try t.expectEqualStrings("", uploadBaseName("dir/"));

    var dir_buf: [64:0]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/sk-upload-{d}", .{c.getpid()});
    try t.expectEqual(@as(c_int, 0), c.mkdir(dir.ptr, 0o700));
    defer _ = c.rmdir(dir.ptr);
    var out: [4096]u8 = undefined;
    var first_buf: [4096]u8 = undefined;
    const first = try openUploadDest(dir, "notes.txt", &first_buf);
    _ = c.close(first.fd);
    defer _ = c.unlink(@as([*:0]const u8, @ptrCast(first.path.ptr)));
    try t.expect(std.mem.endsWith(u8, first.path, "/notes.txt"));
    // The same name again: the suffix goes before the extension.
    const second = try openUploadDest(dir, "notes.txt", &out);
    _ = c.close(second.fd);
    defer _ = c.unlink(@as([*:0]const u8, @ptrCast(second.path.ptr)));
    try t.expect(std.mem.endsWith(u8, second.path, "/notes (1).txt"));
    // A dotfile keeps its whole name as the stem.
    var dot_buf: [4096]u8 = undefined;
    const dot = try openUploadDest(dir, ".env", &dot_buf);
    _ = c.close(dot.fd);
    defer _ = c.unlink(@as([*:0]const u8, @ptrCast(dot.path.ptr)));
    var dot2_buf: [4096]u8 = undefined;
    const dot2 = try openUploadDest(dir, ".env", &dot2_buf);
    _ = c.close(dot2.fd);
    defer _ = c.unlink(@as([*:0]const u8, @ptrCast(dot2.path.ptr)));
    try t.expect(std.mem.endsWith(u8, dot2.path, "/.env (1)"));
}

test "a file reply carries the transfer id, status and path the client keys on" {
    const t = std.testing;
    const a = t.allocator;
    var cl = Client{ .allocator = a, .fd = -1 };
    defer cl.rbuf.deinit(a);
    defer cl.wbuf.deinit(a);
    defer cl.audio_wbuf.deinit(a);
    fileReply(&cl, 42, "done", 1234, "/tmp/x", "");
    const reply = (try wire.peelFrame(cl.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.file_reply, reply.frame.ftype);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "\"xfer\":42") != null);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "\"status\":\"done\"") != null);
    try t.expect(std.mem.indexOf(u8, reply.frame.payload, "\"written\":1234") != null);
}

pub fn handleFileOpen(self: *Daemon, cl: *Client, payload: []const u8) void {
    const Req = struct { xfer: u32 = 0, name: []const u8 = "", size: u64 = 0 };
    const parsed = std.json.parseFromSlice(Req, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch {
        cl.queueErr("bad file_open");
        return;
    };
    defer parsed.deinit();
    const xfer = parsed.value.xfer;

    const s = cl.attached orelse {
        fileReply(cl, xfer, "error", 0, "", "not attached to a session");
        return;
    };
    if (findUpload(self, cl, xfer) != null) {
        fileReply(cl, xfer, "error", 0, "", "duplicate transfer id");
        return;
    }
    var n_for_client: usize = 0;
    for (self.uploads.items) |u| {
        if (u.client == cl) n_for_client += 1;
    }
    if (n_for_client >= max_uploads_per_client) {
        fileReply(cl, xfer, "error", 0, "", "too many concurrent uploads");
        return;
    }

    const base = uploadBaseName(parsed.value.name);
    if (base.len == 0 or base.len > 200 or
        std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..") or
        std.mem.indexOfScalar(u8, base, 0) != null)
    {
        fileReply(cl, xfer, "error", 0, "", "invalid file name");
        return;
    }

    var cwd_buf: [4096]u8 = undefined;
    const cwd = cwdOfPid(s.childPid(), &cwd_buf) orelse {
        fileReply(cl, xfer, "error", 0, "", "cannot determine session directory");
        return;
    };

    var path_buf: [4096]u8 = undefined;
    const dest = openUploadDest(cwd, base, &path_buf) catch {
        fileReply(cl, xfer, "error", 0, "", "cannot create destination file");
        return;
    };

    const up = self.allocator.create(Upload) catch {
        _ = c.close(dest.fd);
        cl.queueErr("oom");
        return;
    };
    const owned_path = self.allocator.dupe(u8, dest.path) catch {
        _ = c.close(dest.fd);
        self.allocator.destroy(up);
        cl.queueErr("oom");
        return;
    };
    up.* = .{ .allocator = self.allocator, .client = cl, .xfer = xfer, .fd = dest.fd, .path = owned_path };
    self.uploads.append(self.allocator, up) catch {
        up.deinit();
        cl.queueErr("oom");
        return;
    };
    // "ready" greenlights the client to start streaming; the path
    // is the real (possibly de-clobbered) name the file landed under.
    fileReply(cl, xfer, "ready", 0, owned_path, "");
}

pub fn handleFileData(self: *Daemon, cl: *Client, payload: []const u8) void {
    const xfer = wire.decodeChanId(payload) orelse return;
    const up = findUpload(self, cl, xfer) orelse return; // aborted/unknown
    const bytes = payload[4..];
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(up.fd, bytes.ptr + off, bytes.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (std.posix.errno(n) == .INTR) continue;
        fileReply(cl, xfer, "error", up.written, up.path, "write failed");
        dropUpload(self, up, true);
        return;
    }
    up.written += bytes.len;
    // Per-chunk ack: the client gates how much it keeps in flight
    // on the gap between bytes sent and bytes acked.
    fileReply(cl, xfer, "progress", up.written, "", "");
}

pub fn handleFileClose(self: *Daemon, cl: *Client, payload: []const u8) void {
    const xfer = wire.decodeChanId(payload) orelse return;
    const up = findUpload(self, cl, xfer) orelse return;
    _ = c.fsync(up.fd);
    _ = c.close(up.fd);
    up.fd = -1;
    fileReply(cl, xfer, "done", up.written, up.path, "");
    dropUpload(self, up, false);
}

// === File download (file_get + reverse file_data) ==========
// The reverse of upload: the daemon reads a file from the remote
// filesystem and streams it to the requesting client.

const max_downloads_per_client = 4;

pub fn dropDownload(self: *Daemon, dl: *Download) void {
    for (self.downloads.items, 0..) |item, i| {
        if (item == dl) {
            _ = self.downloads.swapRemove(i);
            break;
        }
    }
    dl.deinit();
}

/// What a client-named path is allowed to be.

pub fn handleFileGet(self: *Daemon, cl: *Client, payload: []const u8) void {
    const Req = struct { xfer: u32 = 0, path: []const u8 = "" };
    const parsed = std.json.parseFromSlice(Req, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch {
        cl.queueErr("bad file_get");
        return;
    };
    defer parsed.deinit();
    const xfer = parsed.value.xfer;

    const s = cl.attached orelse {
        fileReply(cl, xfer, "error", 0, "", "not attached to a session");
        return;
    };
    var n_for_client: usize = 0;
    for (self.downloads.items) |dl| {
        if (dl.client == cl) n_for_client += 1;
    }
    if (n_for_client >= max_downloads_per_client) {
        fileReply(cl, xfer, "error", 0, "", "too many concurrent downloads");
        return;
    }

    const req_path = parsed.value.path;
    if (req_path.len == 0 or std.mem.indexOfScalar(u8, req_path, 0) != null) {
        fileReply(cl, xfer, "error", 0, "", "invalid path");
        return;
    }

    // Resolve: absolute as-is, otherwise relative to the shell cwd.
    // The user already has shell access to this session, so reading
    // any file they can read is within their existing privilege.
    var abs_buf: [4096]u8 = undefined;
    const abs = blk: {
        if (req_path[0] == '/') break :blk std.fmt.bufPrintZ(&abs_buf, "{s}", .{req_path}) catch {
            fileReply(cl, xfer, "error", 0, "", "path too long");
            return;
        };
        var cwd_buf: [4096]u8 = undefined;
        const cwd = cwdOfPid(s.childPid(), &cwd_buf) orelse {
            fileReply(cl, xfer, "error", 0, "", "cannot determine session directory");
            return;
        };
        break :blk std.fmt.bufPrintZ(&abs_buf, "{s}/{s}", .{ cwd, req_path }) catch {
            fileReply(cl, xfer, "error", 0, "", "path too long");
            return;
        };
    };

    // Client-controlled path: refused by kind before it is ever opened.
    const fd = switch (openChecked(abs.ptr, c.O_RDONLY, 0, .file)) {
        .fd => |fd| fd,
        .refused => |why| {
            fileReply(cl, xfer, "error", 0, "", why);
            return;
        },
        .failed => {
            fileReply(cl, xfer, "error", 0, "", "cannot open file");
            return;
        },
    };
    var st: c.struct_stat = undefined;
    if (c.fstat(fd, &st) != 0) {
        _ = c.close(fd);
        fileReply(cl, xfer, "error", 0, "", "fstat failed");
        return;
    }
    const size: u64 = if (st.st_size > 0) @intCast(st.st_size) else 0;

    const dl = self.allocator.create(Download) catch {
        _ = c.close(fd);
        cl.queueErr("oom");
        return;
    };
    dl.* = .{ .allocator = self.allocator, .client = cl, .xfer = xfer, .fd = fd, .size = size };
    self.downloads.append(self.allocator, dl) catch {
        dl.deinit();
        cl.queueErr("oom");
        return;
    };
    // "ready" carries the size + the basename the client saves under;
    // pumpDownloads then streams the bytes as file_data.
    cl.queueJson(.file_reply, .{
        .xfer = xfer,
        .status = "ready",
        .written = @as(u64, 0),
        .path = uploadBaseName(req_path),
        .message = "",
        .size = size,
    });
}
