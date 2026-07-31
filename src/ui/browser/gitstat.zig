//! Git status overlay for local roots.
//!
//! The worker thread runs `git status` via popen (never on the GLib
//! loop); the idle handback applies the result unless the view died
//! (orphaned) or navigation moved on (generation mismatch).

const std = @import("std");
const c = @import("../../c.zig").c;
const wire = @import("../../mux/wire.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const HostConn = @import("types.zig").HostConn;
const WireJobEv = @import("types.zig").WireJobEv;
const WireReply = @import("types.zig").WireReply;

/// Git-status worker context. The thread runs `git status` via
/// popen (never on the GLib loop); the idle handback applies the
/// result unless the view died (orphaned) or navigation moved on
/// (generation mismatch).
pub const GitCtx = struct {
    view: *BrowserView,
    root: []u8,
    gen: u64,
    out: ?[]u8 = null,
    orphaned: bool = false,

    pub fn destroy(self: *GitCtx) void {
        const a = std.heap.c_allocator;
        a.free(self.root);
        if (self.out) |o| a.free(o);
        a.destroy(self);
    }
};

pub fn clearGitMap(self: *BrowserView) void {
    var it = self.git_map.iterator();
    while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
    self.git_map.clearRetainingCapacity();
}

/// Kick a background `git status` for the tab root. Local roots run
/// it on a worker thread; remote roots as a daemon-side job on the
/// host that owns the repo (feedGit consumes its events). Stale
/// generations are discarded either way.
pub fn refreshGitOverlay(self: *BrowserView, tab: *BTab) void {
    if (tab.hc.host != null) return refreshGitRemote(self, tab);
    self.git_gen +%= 1;
    self.clearGitMap();
    if (self.git_root.len > 0) self.allocator.free(self.git_root);
    self.git_root = self.allocator.dupe(u8, tab.root.path) catch &.{};
    if (self.git_inflight) |g| g.orphaned = true;
    const a = std.heap.c_allocator;
    const ctx = a.create(GitCtx) catch return;
    ctx.* = .{
        .view = self,
        .root = a.dupe(u8, tab.root.path) catch {
            a.destroy(ctx);
            return;
        },
        .gen = self.git_gen,
    };
    self.git_inflight = ctx;
    const th = std.Thread.spawn(.{}, gitThreadMain, .{ctx}) catch {
        self.git_inflight = null;
        ctx.destroy();
        return;
    };
    th.detach();
}

/// Remote root: submit a `git_status` job on the tab's host. Any
/// previous overlay job is cancelled — its events would carry a
/// stale root's records.
fn refreshGitRemote(self: *BrowserView, tab: *BTab) void {
    self.git_gen +%= 1;
    clearGitMap(self);
    if (self.git_root.len > 0) self.allocator.free(self.git_root);
    self.git_root = self.allocator.dupe(u8, tab.root.path) catch &.{};
    if (self.git_rjob != 0) {
        if (self.git_rhc) |old| {
            if (old.state == .ready)
                self.sendOp(old, .{ .req = @as(u32, 0), .op = "job_cancel", .job = self.git_rjob });
        }
    }
    self.git_rjob = 0;
    if (tab.hc.state != .ready) {
        self.git_rhc = null;
        self.git_rreq = 0;
        return;
    }
    self.git_rhc = tab.hc;
    self.git_rreq = self.nextReq();
    self.sendOp(tab.hc, .{ .req = self.git_rreq, .op = "git_status", .path = tab.root.path });
}

/// One porcelain record lands in the aggregate child map (a real
/// change outranks "untracked").
fn applyRecord(self: *BrowserView, path: []const u8, st: u8) void {
    const end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    const child = path[0..end];
    if (child.len == 0) return;
    const gop = self.git_map.getOrPut(child) catch return;
    if (!gop.found_existing) {
        gop.key_ptr.* = self.allocator.dupe(u8, child) catch {
            _ = self.git_map.remove(child);
            return;
        };
        gop.value_ptr.* = st;
    } else if (gop.value_ptr.* == '?' and st != '?') {
        gop.value_ptr.* = st;
    }
}

/// Consume frames of the in-flight remote git_status job.
/// @return true when the frame was ours (the dispatcher stops).
pub fn feedGit(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    if (self.git_rhc != hc) return false;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    switch (ftype) {
        .fs_reply => {
            if (self.git_rreq == 0) return false;
            const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            if (rep.req != self.git_rreq) return false;
            self.git_rreq = 0;
            if (rep.ok and rep.job != 0) {
                self.git_rjob = rep.job;
            } else {
                self.git_rhc = null;
            }
            return true;
        },
        .fs_job => {
            if (self.git_rjob == 0) return false;
            const ev = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            if (ev.job != self.git_rjob) return false;
            if (std.mem.eql(u8, ev.ev, "match")) {
                if (ev.path.len > 0 and ev.text.len > 0) applyRecord(self, ev.path, ev.text[0]);
                return true;
            }
            if (ev.terminalEv()) {
                self.git_rjob = 0;
                self.git_rhc = null;
                if (self.git_map.count() > 0) self.renderCurrent();
            }
            return true;
        },
        else => return false,
    }
}

pub fn gitThreadMain(ctx: *GitCtx) void {
    const a = std.heap.c_allocator;
    // Quoted root; popen runs through sh.
    var cmd: [4400:0]u8 = undefined;
    var w = std.Io.Writer.fixed(cmd[0 .. cmd.len - 1]);
    w.writeAll("cd '") catch return finishGit(ctx);
    for (ctx.root) |ch| {
        if (ch == '\'') w.writeAll("'\\''") catch return finishGit(ctx) else w.writeByte(ch) catch return finishGit(ctx);
    }
    w.writeAll("' 2>/dev/null && git status --porcelain --no-renames -z 2>/dev/null | head -c 65536 && printf '\\x01' && git rev-parse --show-prefix 2>/dev/null") catch return finishGit(ctx);
    cmd[w.buffered().len] = 0;
    const fp = c.popen(&cmd, "r") orelse return finishGit(ctx);
    var out: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, fp);
        if (n == 0) break;
        out.appendSlice(a, buf[0..n]) catch break;
        if (out.items.len > 128 * 1024) break;
    }
    _ = c.pclose(fp);
    ctx.out = out.toOwnedSlice(a) catch null;
    finishGit(ctx);
}

pub fn finishGit(ctx: *GitCtx) void {
    _ = c.g_idle_add(@ptrCast(&onGitIdle), @ptrCast(ctx));
}

pub fn onGitIdle(user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx: *GitCtx = @ptrCast(@alignCast(user.?));
    defer ctx.destroy();
    if (ctx.orphaned) return 0;
    const self = ctx.view;
    if (self.git_inflight == ctx) self.git_inflight = null;
    if (ctx.gen != self.git_gen) return 0;
    const out = ctx.out orelse return 0;
    // out = "<porcelain -z>\x01<prefix>\n"
    const sep = std.mem.indexOfScalar(u8, out, 1) orelse return 0;
    const status = out[0..sep];
    var prefix = std.mem.trim(u8, out[sep + 1 ..], "\n ");
    _ = &prefix;
    var it = std.mem.tokenizeScalar(u8, status, 0);
    while (it.next()) |rec| {
        if (rec.len < 4) continue;
        const st: u8 = if (rec[0] != ' ' and rec[0] != '?') rec[0] else rec[1];
        var path = rec[3..];
        // Paths are repo-root-relative; strip the prefix of the
        // browsed subdir, skip entries outside it.
        if (prefix.len > 0) {
            if (!std.mem.startsWith(u8, path, prefix)) continue;
            path = path[prefix.len..];
        }
        if (path.len == 0) continue;
        applyRecord(self, path, st);
    }
    if (self.git_map.count() > 0) self.renderCurrent();
    return 0;
}
