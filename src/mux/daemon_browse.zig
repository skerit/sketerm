//! Remote directory browse (`file_list`): a bounded listing of one
//! directory for the GUI's remote file picker. Split out of
//! daemon_serve.zig.

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

// === Remote directory browse (file_list) ===================
// Lets the GUI offer a "remote file picker" without the user
// typing paths. Read-only; no state kept (a one-shot reply).

/// Cap on entries per listing — bounds the reply size for huge dirs.
const max_list_entries = 4096;

/// One directory entry on the wire (JSON-serialized in file_listing).
pub const ListEntry = struct { name: []const u8, dir: bool, size: u64 };

pub fn listingError(cl: *Client, xfer: u32, path: []const u8, msg: []const u8) void {
    cl.queueJson(.file_listing, .{
        .xfer = xfer,
        .path = path,
        .entries = &[_]ListEntry{},
        .@"error" = msg,
        .truncated = false,
    });
}

test "a listing error is an empty listing on the frame the picker waits for" {
    const t = std.testing;
    const a = t.allocator;
    var cl = Client{ .allocator = a, .fd = -1 };
    defer cl.rbuf.deinit(a);
    defer cl.wbuf.deinit(a);
    defer cl.audio_wbuf.deinit(a);
    listingError(&cl, 9, "/nope", "no such directory");
    const reply = (try wire.peelFrame(cl.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.file_listing, reply.frame.ftype);
    const Listing = struct { xfer: u32 = 0, path: []const u8 = "", entries: []const ListEntry = &.{}, @"error": []const u8 = "", truncated: bool = true };
    const parsed = try std.json.parseFromSlice(Listing, a, reply.frame.payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try t.expectEqual(@as(u32, 9), parsed.value.xfer);
    try t.expectEqualStrings("/nope", parsed.value.path);
    try t.expectEqual(@as(usize, 0), parsed.value.entries.len);
    try t.expectEqualStrings("no such directory", parsed.value.@"error");
    try t.expect(!parsed.value.truncated);
}

test "a directory listing is bounded and answered on the same frame" {
    const t = std.testing;
    const a = t.allocator;
    var dir_buf: [64:0]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "/tmp/sk-browse-{d}", .{c.getpid()});
    try t.expectEqual(@as(c_int, 0), c.mkdir(dir.ptr, 0o700));
    defer _ = c.rmdir(dir.ptr);
    var sub_buf: [80:0]u8 = undefined;
    const sub = try std.fmt.bufPrintZ(&sub_buf, "{s}/sub", .{dir});
    try t.expectEqual(@as(c_int, 0), c.mkdir(sub.ptr, 0o700));
    defer _ = c.rmdir(sub.ptr);
    var file_buf: [80:0]u8 = undefined;
    const file = try std.fmt.bufPrintZ(&file_buf, "{s}/f.txt", .{dir});
    const fd = c.open(file.ptr, c.O_WRONLY | c.O_CREAT, @as(c_uint, 0o600));
    try t.expect(fd >= 0);
    try t.expectEqual(@as(isize, 3), c.write(fd, "abc", 3));
    _ = c.close(fd);
    defer _ = c.unlink(file.ptr);

    var empty: [0]u8 = .{};
    var d = Daemon{ .allocator = a, .listen_fd = -1, .sock_path = empty[0..], .role = .worker };
    // Attach-scoped: an absolute path never consults the session's cwd,
    // so a bare Session record is enough here.
    var session: Session = undefined;
    session.exited = false;
    var cl = Client{ .allocator = a, .fd = -1, .attached = &session };
    defer cl.rbuf.deinit(a);
    defer cl.wbuf.deinit(a);
    defer cl.audio_wbuf.deinit(a);
    var req_buf: [128]u8 = undefined;
    handleFileList(&d, &cl, try std.fmt.bufPrint(&req_buf, "{{\"xfer\":3,\"path\":\"{s}\"}}", .{dir}));
    cl.attached = null;
    const reply = (try wire.peelFrame(cl.wbuf.items)) orelse return error.TestUnexpectedResult;
    try t.expectEqual(wire.FrameType.file_listing, reply.frame.ftype);
    const Listing = struct { xfer: u32 = 0, entries: []const ListEntry = &.{}, @"error": []const u8 = "" };
    const parsed = try std.json.parseFromSlice(Listing, a, reply.frame.payload, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try t.expectEqual(@as(u32, 3), parsed.value.xfer);
    try t.expectEqualStrings("", parsed.value.@"error");
    var saw_dir = false;
    var saw_file = false;
    for (parsed.value.entries) |e| {
        if (std.mem.eql(u8, e.name, "sub")) saw_dir = e.dir;
        if (std.mem.eql(u8, e.name, "f.txt")) saw_file = !e.dir and e.size == 3;
    }
    try t.expect(saw_dir);
    try t.expect(saw_file);
}

pub fn handleFileList(self: *Daemon, cl: *Client, payload: []const u8) void {
    const Req = struct { xfer: u32 = 0, path: []const u8 = "" };
    const parsed = std.json.parseFromSlice(Req, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch {
        cl.queueErr("bad file_list");
        return;
    };
    defer parsed.deinit();
    const xfer = parsed.value.xfer;

    const s = cl.attached orelse {
        listingError(cl, xfer, "", "not attached to a session");
        return;
    };

    // Resolve the directory: empty → cwd, absolute as-is, else
    // relative to cwd.
    var dir_z: [4096]u8 = undefined;
    const req_path = parsed.value.path;
    const dirpath: [:0]const u8 = blk: {
        if (req_path.len == 0 or req_path[0] != '/') {
            var cwd_buf: [4096]u8 = undefined;
            const cwd = cwdOfPid(s.childPid(), &cwd_buf) orelse {
                listingError(cl, xfer, "", "cannot determine session directory");
                return;
            };
            if (req_path.len == 0) {
                break :blk std.fmt.bufPrintZ(&dir_z, "{s}", .{cwd}) catch {
                    listingError(cl, xfer, "", "path too long");
                    return;
                };
            }
            break :blk std.fmt.bufPrintZ(&dir_z, "{s}/{s}", .{ cwd, req_path }) catch {
                listingError(cl, xfer, "", "path too long");
                return;
            };
        }
        break :blk std.fmt.bufPrintZ(&dir_z, "{s}", .{req_path}) catch {
            listingError(cl, xfer, "", "path too long");
            return;
        };
    };

    // Canonicalize for the reported path (collapses .. and symlinks)
    // so the GUI's address bar stays clean.
    var real_buf: [4096]u8 = undefined;
    const resolved: []const u8 = if (c.realpath(dirpath.ptr, &real_buf)) |r|
        std.mem.span(@as([*:0]const u8, @ptrCast(r)))
    else
        dirpath;

    const dir = c.opendir(dirpath.ptr) orelse {
        listingError(cl, xfer, resolved, "cannot open directory");
        return;
    };
    defer _ = c.closedir(dir);

    const Entry = ListEntry;
    var arena_state = std.heap.ArenaAllocator.init(self.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var entries: std.ArrayList(Entry) = .empty;
    var truncated = false;

    while (c.readdir(dir)) |de| {
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&de.*.d_name)));
        if (name.len == 0) continue;
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        // JSON can't carry non-UTF-8; skip such names (very rare).
        if (!std.unicode.utf8ValidateSlice(name)) continue;
        if (entries.items.len >= max_list_entries) {
            truncated = true;
            break;
        }
        // Resolve type/size. d_type is a fast path; fall back to a
        // stat (following symlinks so a link to a dir browses).
        var is_dir = de.*.d_type == c.DT_DIR;
        var size: u64 = 0;
        if (de.*.d_type != c.DT_DIR) {
            var full_z: [4096]u8 = undefined;
            if (std.fmt.bufPrintZ(&full_z, "{s}/{s}", .{ dirpath, name })) |fp| {
                var st: c.struct_stat = undefined;
                if (c.stat(fp.ptr, &st) == 0) {
                    is_dir = (st.st_mode & c.S_IFMT) == c.S_IFDIR;
                    if (!is_dir and st.st_size > 0) size = @intCast(st.st_size);
                }
            } else |_| {}
        }
        const owned = arena.dupe(u8, name) catch continue;
        entries.append(arena, .{ .name = owned, .dir = is_dir, .size = size }) catch break;
    }

    // Directories first, then case-insensitive by name.
    std.mem.sort(Entry, entries.items, {}, struct {
        fn lt(_: void, a: Entry, b: Entry) bool {
            if (a.dir != b.dir) return a.dir;
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.lt);

    cl.queueJson(.file_listing, .{
        .xfer = xfer,
        .path = resolved,
        .entries = entries.items,
        .@"error" = "",
        .truncated = truncated,
    });
}
