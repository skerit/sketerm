//! Compare-two-files: a daemon-side `diff -u` job streamed into a
//! monospace viewer window. Same-host pairs only — the diff runs on
//! the host that owns both files, so only its text crosses the wire.

const std = @import("std");
const c = @import("../../c.zig").c;
const wire = @import("../../mux/wire.zig");

const BrowserView = @import("view.zig").BrowserView;
const HostConn = @import("types.zig").HostConn;
const WireJobEv = @import("types.zig").WireJobEv;
const WireReply = @import("types.zig").WireReply;

/// The one in-flight compare (a second request replaces it).
pub const DiffState = struct {
    hc: ?*HostConn = null,
    req: u32 = 0,
    job: u64 = 0,
    buf: std.ArrayList(u8) = .empty,
    title: [512]u8 = undefined,
    title_len: usize = 0,

    pub fn deinit(self: *DiffState, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
    }
};

/// Compare the two selected files (menu verb). Cross-host pairs are
/// refused honestly: the diff runs where the files live.
pub fn compareSelected(self: *BrowserView, a_path: []const u8, b_path: []const u8) void {
    const tab = self.currentTab() orelse return;
    if (tab.hc.state != .ready) {
        self.setStatus("not connected");
        return;
    }
    const st = &self.diff;
    if (st.job != 0) {
        if (st.hc) |old| {
            if (old.state == .ready)
                self.sendOp(old, .{ .req = @as(u32, 0), .op = "job_cancel", .job = st.job });
        }
    }
    st.buf.clearRetainingCapacity();
    st.job = 0;
    st.hc = tab.hc;
    st.req = self.nextReq();
    const t = std.fmt.bufPrint(&st.title, "{s} vs {s}", .{
        std.fs.path.basename(a_path), std.fs.path.basename(b_path),
    }) catch "diff";
    st.title_len = t.len;
    self.sendOp(tab.hc, .{ .req = st.req, .op = "diff", .path = a_path, .to = b_path });
    self.setStatusFmt("comparing {s}…", .{t});
}

/// Consume the in-flight diff job's frames.
/// @return true when the frame was ours (the dispatcher stops).
pub fn feedDiff(self: *BrowserView, hc: *HostConn, ftype: wire.FrameType, payload: []const u8) bool {
    const st = &self.diff;
    if (st.hc != hc) return false;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    switch (ftype) {
        .fs_reply => {
            if (st.req == 0) return false;
            const rep = std.json.parseFromSliceLeaky(WireReply, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            if (rep.req != st.req) return false;
            st.req = 0;
            if (rep.ok and rep.job != 0) {
                st.job = rep.job;
            } else {
                st.hc = null;
                self.setStatusFmt("compare failed: {s}", .{if (rep.@"error".len > 0) rep.@"error" else "refused"});
            }
            return true;
        },
        .fs_job => {
            if (st.job == 0) return false;
            const ev = std.json.parseFromSliceLeaky(WireJobEv, arena.allocator(), payload, .{
                .ignore_unknown_fields = true,
            }) catch return false;
            if (ev.job != st.job) return false;
            if (std.mem.eql(u8, ev.ev, "line")) {
                if (st.buf.items.len < 512 * 1024) {
                    st.buf.appendSlice(self.allocator, ev.text) catch {};
                    st.buf.append(self.allocator, '\n') catch {};
                }
                return true;
            }
            if (ev.terminalEv()) {
                st.job = 0;
                st.hc = null;
                if (std.mem.eql(u8, ev.ev, "done")) {
                    showDiffWindow(self);
                } else {
                    self.setStatusFmt("compare failed: {s}", .{if (ev.message.len > 0) ev.message else "error"});
                }
            }
            return true;
        },
        else => return false,
    }
}

/// A plain transient monospace text window — the same shape as the
/// informational toplevels (never a modal sheet).
fn showDiffWindow(self: *BrowserView) void {
    const st = &self.diff;
    if (st.buf.items.len == 0) {
        self.setStatus("files are identical");
        return;
    }
    const win = c.gtk_window_new();
    var tz: [560:0]u8 = undefined;
    const t = std.fmt.bufPrintZ(&tz, "Compare: {s}", .{st.title[0..st.title_len]}) catch "Compare";
    c.gtk_window_set_title(@ptrCast(win), t.ptr);
    c.gtk_window_set_default_size(@ptrCast(win), 760, 560);
    const scroll = c.gtk_scrolled_window_new();
    const tv = c.gtk_text_view_new();
    c.gtk_text_view_set_editable(@ptrCast(tv), 0);
    c.gtk_text_view_set_monospace(@ptrCast(tv), 1);
    c.gtk_text_view_set_left_margin(@ptrCast(tv), 8);
    c.gtk_text_view_set_top_margin(@ptrCast(tv), 8);
    const tb = c.gtk_text_view_get_buffer(@ptrCast(tv));
    c.gtk_text_buffer_set_text(tb, st.buf.items.ptr, @intCast(st.buf.items.len));
    c.gtk_scrolled_window_set_child(@ptrCast(scroll), tv);
    c.gtk_window_set_child(@ptrCast(win), scroll);
    if (self.ownerWindow()) |ow| c.gtk_window_set_transient_for(@ptrCast(win), @ptrCast(@alignCast(ow.app_window)));
    c.gtk_window_present(@ptrCast(win));
    st.buf.clearRetainingCapacity();
}
