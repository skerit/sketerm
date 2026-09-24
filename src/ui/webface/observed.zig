//! Observed pages (webwatch.zig), the face half: a face showing another
//! client's view, seeded and laid out from the owner's geometry. Split out of `webface.zig`; the `WebFace` methods are free functions
//! taking `*WebFace`, re-exported from `WebFace` by name.

const std = @import("std");
const c = @import("../../c.zig").c;
const proto = @import("../../web/protocol.zig");
const watchgeom = @import("../../web/watchgeom.zig");
const host_mod = @import("../webface.zig");
const WebFace = host_mod.WebFace;

// ---- observed pages (webwatch.zig) --------------------------------

/// What the announcement carried, before the subscription answers:
/// the owner's geometry and the page identity, so the chrome reads
/// right from the first frame.
pub fn seedObserved(self: *WebFace, w: u16, h: u16, scale_x1000: u16, url: []const u8, title: []const u8) void {
    self.obs_w = w;
    self.obs_h = h;
    self.obs_scale = if (scale_x1000 == 0) 1000 else scale_x1000;
    if (url.len != 0) {
        self.setUrl(url);
        // The bar may already hold focus (a page attaches with no
        // address, and focus follows the new page); nobody has
        // typed into it yet, so the seed is written regardless.
        if (!self.widgets_dead) {
            if (self.allocator.dupeZ(u8, url) catch null) |z| {
                defer self.allocator.free(z);
                c.gtk_editable_set_text(@ptrCast(self.entry), z.ptr);
            }
        }
    }
    if (title.len != 0) self.onTitle(title);
    self.layoutObserved();
}

/// `ev_observe_state{subscribed}`: the owner's geometry (it may
/// have resized) and whether this GUI holds control.
pub fn onObserved(self: *WebFace, w: u16, h: u16, scale_x1000: u16, control: bool) void {
    self.obs_w = w;
    self.obs_h = h;
    self.obs_scale = if (scale_x1000 == 0) 1000 else scale_x1000;
    self.obs_control = control;
    self.clearStatus();
    self.layoutObserved();
}

/// `ev_observe_state{refused}`: this page will never show.
pub fn observeRefused(self: *WebFace, reason: []const u8) void {
    var buf: [320]u8 = undefined;
    self.setStatus(std.fmt.bufPrint(&buf, "The assistant's page cannot be watched: {s}", .{reason}) catch "The assistant's page cannot be watched.", false);
}

/// Ask for (or give up) control of the observed page; the helper
/// answers with `ev_observe_state`.
pub fn postObserveControl(self: *WebFace, control: bool) void {
    if (!self.observed or !self.view_live) return;
    self.cl.post(proto.ObserveControl{ .view = self.view, .control = if (control) 1 else 0 });
}

/// Place the fitted frame: the picture is sized to the fit and
/// offset by its margins, and input subtracts the same offsets
/// (`snap_dx/dy`) before dividing by the fit's scale.
pub fn layoutObserved(self: *WebFace) void {
    if (!self.observed or self.widgets_dead) return;
    const alloc = self.allocationSize();
    const lw = if (self.frame_lw != 0) self.frame_lw else self.obs_w;
    const lh = if (self.frame_lh != 0) self.frame_lh else self.obs_h;
    const f = watchgeom.fit(alloc.w, alloc.h, lw, lh);
    self.obs_fit = f;
    self.snap_dx = f.x;
    self.snap_dy = f.y;
    // All FOUR margins: a size request is only a minimum, and a
    // GtkPicture's natural size is its paintable's, so with just
    // start/top margins the picture was allocated wider or taller
    // than the fit and CONTAIN re-centred the frame inside that,
    // moving the drawn pixels away from where `obs_fit` (and so the
    // pointer mapping) says they are. Pinning every side makes the
    // allocation exactly the fit.
    const end_x: c_int = @max(0, @as(c_int, alloc.w) - @as(c_int, f.x) - @as(c_int, f.w));
    const end_y: c_int = @max(0, @as(c_int, alloc.h) - @as(c_int, f.y) - @as(c_int, f.h));
    c.gtk_widget_set_margin_start(self.picture, f.x);
    c.gtk_widget_set_margin_top(self.picture, f.y);
    c.gtk_widget_set_margin_end(self.picture, end_x);
    c.gtk_widget_set_margin_bottom(self.picture, end_y);
    c.gtk_widget_set_size_request(self.picture, f.w, f.h);
}
