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

/// Floor for the deep-change re-poll (below). Watches cover the
/// browsed directory and whatever subdirectories are expanded, so a
/// commit or an edit ANYWHERE ELSE under the root produces no delta
/// at all; without a poll its badge stays wrong until the next
/// navigation.
const POLL_MIN_MS: i64 = 20_000;
/// ...and its ceiling, and the multiple of the last job's duration
/// that sets the interval between them. A repository where git status
/// costs a second is re-polled every 40s, not every 20 — the poll
/// paces itself off the cost it measured rather than a guess.
const POLL_MAX_MS: i64 = 300_000;
const POLL_COST_FACTOR: i64 = 40;

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
    // The repository answer belongs to the OLD root; keeping it would
    // make a non-repo inherit the previous folder's branch.
    if (!same_root) self.git_repo.clear();
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
    if (tab.hc.state != .ready) {
        self.git_repo.clear();
        return;
    }
    self.git_cache.note(host, tab.root.path, now);
    self.git_rhc = tab.hc;
    self.git_rreq = self.nextReq();
    self.git_started_ms = now;
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

/// Remember what the job just cost, which is what paces the re-poll.
fn notePollCost(self: *BrowserView) void {
    if (self.git_started_ms == 0) return;
    const took = clock.nowMs() -% self.git_started_ms;
    self.git_started_ms = 0;
    self.git_poll_ms = std.math.clamp(took * POLL_COST_FACTOR, POLL_MIN_MS, POLL_MAX_MS);
}

/// Arm (or leave armed) the deep-change re-poll for a repository root.
///
/// Only a repository is polled, and the tick itself skips a face that
/// is not on screen. Window FOCUS is deliberately not part of the
/// gate: it is not a state the GUI can rely on resolving (a headless
/// compositor focuses nothing), and a wrong badge in a visible
/// background window is still a wrong badge.
fn ensurePoll(self: *BrowserView) void {
    if (self.widgets_dead or self.git_poll_src != 0) return;
    if (!self.git_repo.is_repo) return;
    const ms = @max(POLL_MIN_MS, self.git_poll_ms);
    self.git_poll_src = c.g_timeout_add(@intCast(ms), @ptrCast(&onGitPollTick), @ptrCast(self));
}

fn onGitPollTick(user: ?*anyopaque) callconv(.c) c.gboolean {
    const self: *BrowserView = @ptrCast(@alignCast(user.?));
    self.git_poll_src = 0;
    if (self.widgets_dead) return 0;
    const tab = gitTab(self) orelse return 0;
    if (!self.git_repo.is_repo) return 0;
    if (c.gtk_widget_get_mapped(self.root_box) == 0) {
        // The face is not on screen at all (another tab, or a hidden
        // window): nothing to repaint, but stay armed.
        ensurePoll(self);
        return 0;
    }
    refreshGit(self, tab, true);
    return 0; // one-shot; the reply re-arms with a fresh interval
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
                if (ev.path.len == 0) return true;
                // `xy` is the porcelain-v2 pair; a daemon too old to
                // send it leaves the collapsed `text` character as the
                // only information, and the overlay renders that as
                // the single letter it always did.
                self.git.applyInput(.{
                    .path = ev.path,
                    .x = if (ev.xy.len == 2) ev.xy[0] else 0,
                    .y = if (ev.xy.len == 2) ev.xy[1] else 0,
                    .legacy = if (ev.text.len > 0) ev.text[0] else 0,
                    .orig = ev.orig,
                    .submodule = std.mem.eql(u8, ev.kind, "submodule"),
                });
                return true;
            }
            if (std.mem.eql(u8, ev.ev, "repo")) {
                self.git_repo.set(.{
                    .is_repo = ev.repo,
                    .detached = ev.detached,
                    .initial = ev.initial,
                    .at_root = ev.root,
                    .truncated = ev.truncated,
                    .branch = ev.branch,
                    .upstream = ev.upstream,
                    .oid = ev.text,
                    .ahead = ev.ahead,
                    .behind = ev.behind,
                    .have_ab = ev.have_ab,
                });
                return true;
            }
            if (ev.terminalEv()) {
                self.git_rjob = 0;
                self.git_rhc = null;
                notePollCost(self);
                // Always render: a repository that went CLEAN has an
                // empty overlay and still has a status line to change,
                // and the rows that carried the old badges must lose
                // them.
                if (gitTab(self)) |tab| noteOverlayRows(self, tab);
                self.renderCurrent();
                ensurePoll(self);
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

/// ", on main +2 -1, 3 modified" for the status line, or empty.
///
/// Everything about WHAT to say lives in `filebrowser/gitstatus.zig`;
/// this only decides that the overlay still describes this tab.
pub fn summaryNote(self: *BrowserView, tab: *BTab, buf: []u8) []const u8 {
    if (!std.mem.eql(u8, self.git_root, tab.root.path)) return buf[0..0];
    if (!std.mem.eql(u8, self.git_host, tab.hc.host orelse "")) return buf[0..0];
    return gitstatus.statusNote(&self.git_repo, &self.git, buf);
}

/// The tooltip for one row's chip, or empty when it carries none.
pub fn tooltipFor(self: *BrowserView, tab: *BTab, dir: *const Dir, e: Entry, buf: []u8) []const u8 {
    if (self.git.isEmpty()) return buf[0..0];
    if (!std.mem.eql(u8, self.git_root, tab.root.path)) return buf[0..0];
    if (!std.mem.eql(u8, self.git_host, tab.hc.host orelse "")) return buf[0..0];
    var key: [4096]u8 = undefined;
    const rel = gitstatus.relativeKey(tab.root.path, dir.path, e.name, &key) orelse return buf[0..0];
    const row = self.git.get(rel) orelse return buf[0..0];
    return row.describe(buf);
}
