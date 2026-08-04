//! Version-control overlay: submit the daemon's `git_status` job for
//! the browsed directory and fold its records into `view.git`.
//!
//! The GUI never runs git itself — local and remote roots take the
//! exact same path, a job on the daemon that OWNS the files, so a
//! remote repository behaves identically to a local one. All parsing,
//! rollup and display decisions live in `filebrowser/gitstatus.zig`.

const std = @import("std");
const c = @import("../../c.zig").c;
const wire = @import("../../mux/wire.zig");
const clock = @import("../../util/clock.zig");
const gitstatus = @import("../../filebrowser/gitstatus.zig");

const BTab = @import("types.zig").BTab;
const BrowserView = @import("view.zig").BrowserView;
const Dir = @import("types.zig").Dir;
const Entry = @import("types.zig").Entry;
const HostConn = @import("types.zig").HostConn;
const WireJobEv = @import("types.zig").WireJobEv;
const WireReply = @import("types.zig").WireReply;

/// Trailing debounce for change-driven refreshes. A file operation or
/// an editor save lands as a burst of watch deltas; one job per burst
/// is the whole point of the timer.
const DELTA_DEBOUNCE_MS: c.guint = 750;

/// Kick a `git_status` job for the tab root on the host that owns it.
///
/// Skipped when the same root was asked recently (`git_cache`) and the
/// caller did not force it — walking back and forth between folders,
/// or a directory outside any repository, must not respawn git per
/// step. Stale generations are discarded on arrival.
pub fn refreshGitOverlay(self: *BrowserView, tab: *BTab) void {
    refreshGit(self, tab, false);
}

/// Refresh ignoring the recency cache: explicit reload, or a change
/// notification for the browsed directory.
pub fn refreshGitForced(self: *BrowserView, tab: *BTab) void {
    refreshGit(self, tab, true);
}

fn refreshGit(self: *BrowserView, tab: *BTab, force: bool) void {
    const host = tab.hc.host orelse "";
    const same_root = std.mem.eql(u8, self.git_root, tab.root.path) and
        std.mem.eql(u8, self.git_host, host);
    const now = clock.nowMs();
    if (force) {
        self.git_cache.invalidate(host, tab.root.path);
    } else if (same_root and self.git_cache.fresh(host, tab.root.path, now)) {
        // Already answered for this exact root recently; the overlay
        // on screen is the answer.
        return;
    }

    // A refresh IN PLACE drops badges the next splice must repaint,
    // and renderList only rebuilds rows the tab called changed. After
    // a navigation the old rows are gone with their directory, so
    // there is nothing to mark.
    if (same_root) noteOverlayRows(self, tab);
    self.git.clear();
    setRootKey(self, tab.root.path, host);

    // A previous job's events would carry another root's records.
    if (self.git_rjob != 0) {
        if (self.git_rhc) |old| {
            if (old.state == .ready)
                self.sendOp(old, .{ .req = @as(u32, 0), .op = "job_cancel", .job = self.git_rjob });
        }
    }
    self.git_rjob = 0;
    self.git_rreq = 0;
    self.git_rhc = null;
    if (tab.hc.state != .ready) return;
    self.git_cache.note(host, tab.root.path, now);
    self.git_rhc = tab.hc;
    self.git_rreq = self.nextReq();
    self.sendOp(tab.hc, .{ .req = self.git_rreq, .op = "git_status", .path = tab.root.path });
}

fn setRootKey(self: *BrowserView, path: []const u8, host: []const u8) void {
    if (self.git_root.len > 0) self.allocator.free(self.git_root);
    if (self.git_host.len > 0) self.allocator.free(self.git_host);
    self.git_root = self.allocator.dupe(u8, path) catch &.{};
    self.git_host = self.allocator.dupe(u8, host) catch &.{};
}

/// The tab the overlay describes, or null when the visible tab moved
/// elsewhere (another root, another host).
pub fn gitTab(self: *BrowserView) ?*BTab {
    const tab = self.currentTab() orelse return null;
    if (!std.mem.eql(u8, self.git_root, tab.root.path)) return null;
    if (!std.mem.eql(u8, self.git_host, tab.hc.host orelse "")) return null;
    return tab;
}

/// Mark every currently-badged row as content-changed so the next
/// windowed splice rebuilds it. Imprecision costs a repaint; skipping
/// it leaves stale badges on screen.
fn noteOverlayRows(self: *BrowserView, tab: *BTab) void {
    if (self.git.isEmpty()) return;
    var it = self.git.map.iterator();
    while (it.next()) |kv| {
        var buf: [4096]u8 = undefined;
        const full = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{
            tab.root.path,
            if (tab.root.path.len == 1) "" else "/",
            kv.key_ptr.*,
        }) catch {
            tab.changed_all = true;
            return;
        };
        tab.noteChangedFull(full);
    }
}

/// Schedule a debounced forced refresh after a change notification.
pub fn scheduleGitRefresh(self: *BrowserView) void {
    if (self.widgets_dead or self.git_delta_src != 0) return;
    self.git_delta_src = c.g_timeout_add(DELTA_DEBOUNCE_MS, @ptrCast(&onGitDeltaTick), @ptrCast(self));
}

fn onGitDeltaTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.git_delta_src = 0;
    if (self.widgets_dead) return 0;
    const tab = self.currentTab() orelse return 0;
    refreshGit(self, tab, true);
    return 0; // one-shot
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
                if (ev.path.len > 0 and ev.text.len > 0) self.git.apply(ev.path, ev.text[0]);
                return true;
            }
            if (ev.terminalEv()) {
                self.git_rjob = 0;
                self.git_rhc = null;
                if (!self.git.isEmpty()) {
                    if (gitTab(self)) |tab| noteOverlayRows(self, tab);
                    self.renderCurrent();
                }
            }
            return true;
        },
        else => return false,
    }
}

/// The chip for one listing row, or null when it carries none.
///
/// `dir` may be the tab root or an expanded subdirectory; anything
/// outside the root (a miller ancestor column) has no answer, because
/// the overlay only covers what was asked for.
pub fn badgeFor(self: *BrowserView, tab: *BTab, dir: *const Dir, e: Entry) ?gitstatus.Badge {
    if (self.git.isEmpty()) return null;
    if (!std.mem.eql(u8, self.git_root, tab.root.path)) return null;
    if (!std.mem.eql(u8, self.git_host, tab.hc.host orelse "")) return null;
    var buf: [4096]u8 = undefined;
    const rel = gitstatus.relativeKey(tab.root.path, dir.path, e.name, &buf) orelse return null;
    return self.git.badge(rel);
}

/// ", 3 modified, 1 untracked" for the status line, or empty.
///
/// The daemon's `git_status` reports records only — no branch, no
/// ahead/behind — so this is everything there is to say.
pub fn summaryNote(self: *BrowserView, tab: *BTab, buf: []u8) []const u8 {
    if (!std.mem.eql(u8, self.git_root, tab.root.path)) return buf[0..0];
    if (!std.mem.eql(u8, self.git_host, tab.hc.host orelse "")) return buf[0..0];
    return self.git.summary(buf);
}
