//! Git status overlay for local roots.
//!
//! The worker thread runs `git status` via popen (never on the GLib
//! loop); the idle handback applies the result unless the view died
//! (orphaned) or navigation moved on (generation mismatch).

const std = @import("std");
const c = @import("../../c.zig").c;

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;

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

/// Kick a background `git status` for a LOCAL root. Results land
/// via idle handback; a stale generation is discarded.
pub fn refreshGitOverlay(self: *BrowserView, tab: *BTab) void {
    if (tab.hc.host != null) return;
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
        const end = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
        const child = path[0..end];
        if (child.len == 0) continue;
        const gop = self.git_map.getOrPut(child) catch continue;
        if (!gop.found_existing) {
            gop.key_ptr.* = self.allocator.dupe(u8, child) catch {
                _ = self.git_map.remove(child);
                continue;
            };
            gop.value_ptr.* = st;
        } else if (gop.value_ptr.* == '?' and st != '?') {
            // A real change outranks "untracked" for aggregation.
            gop.value_ptr.* = st;
        }
    }
    if (self.git_map.count() > 0) self.renderCurrent();
    return 0;
}
