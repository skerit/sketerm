//! Shader config dialog — sliders + color pickers generated from
//! the shader's own parameter declarations (RetroArch `#pragma
//! parameter` lines and sketerm's //@color, with //@name and
//! //@desc feeding the header). Every change applies live (uniform
//! upload happens per frame) and persists as a `shader_param.*`
//! config entry.

const std = @import("std");
const c = @import("../c.zig").c;
const cast = @import("../util/cast.zig");
const Window = @import("window.zig").Window;
const shader_pass = @import("../render/shader_pass.zig");

const Ctx = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    params: [shader_pass.MAX_PARAMS]shader_pass.Param = undefined,
    params_len: usize = 0,
    meta: shader_pass.Meta = .{},
};

const RowCtx = struct {
    /// Own copy — freeRowCtx (widget destroy-notify) can run AFTER
    /// the dialog's Ctx was freed on "closed"; never deref ctx there.
    allocator: std.mem.Allocator,
    ctx: *Ctx,
    idx: usize,
};

/// Open the dialog for the focused pane's effective shader. With no
/// shader active, falls through to false (caller may offer the file
/// picker instead).
pub fn open(win: *Window) bool {
    const pane = win.focusedPane() orelse return false;
    const src: []const u8 = blk: {
        if (pane.shader_own.src) |s| break :blk s;
        if (win.shader_source.src) |s| break :blk s;
        return false;
    };

    const ctx = win.allocator.create(Ctx) catch return false;
    ctx.* = .{ .allocator = win.allocator, .win = win };
    ctx.params_len = shader_pass.parseParams(src, &ctx.params, &ctx.meta);

    const dialog = c.adw_preferences_dialog_new();
    const title_z = dupZ(win.allocator, if (ctx.meta.title().len > 0) ctx.meta.title() else "Shader") orelse {
        win.allocator.destroy(ctx);
        return false;
    };
    defer win.allocator.free(title_z);
    c.adw_dialog_set_title(@ptrCast(@alignCast(dialog)), title_z.ptr);

    const page = c.adw_preferences_page_new();
    const group = c.adw_preferences_group_new();
    c.adw_preferences_group_set_title(@ptrCast(@alignCast(group)), title_z.ptr);
    if (ctx.meta.desc().len > 0) {
        if (dupZ(win.allocator, ctx.meta.desc())) |d| {
            defer win.allocator.free(d);
            c.adw_preferences_group_set_description(@ptrCast(@alignCast(group)), d.ptr);
        }
    }

    if (ctx.params_len == 0) {
        const row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), "This shader declares no tunable parameters");
        c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), "Add #pragma parameter / //@color lines to the GLSL file.");
        c.adw_preferences_group_add(@ptrCast(@alignCast(group)), @ptrCast(@alignCast(row)));
    }

    var i: usize = 0;
    while (i < ctx.params_len) : (i += 1) {
        const p = &ctx.params[i];
        const row = c.adw_action_row_new();
        if (dupZ(win.allocator, p.label())) |lz| {
            defer win.allocator.free(lz);
            c.adw_preferences_row_set_title(@ptrCast(@alignCast(row)), lz.ptr);
        }
        if (dupZ(win.allocator, p.name())) |nz| {
            defer win.allocator.free(nz);
            c.adw_action_row_set_subtitle(@ptrCast(@alignCast(row)), nz.ptr);
        }

        const rctx = win.allocator.create(RowCtx) catch continue;
        rctx.* = .{ .allocator = win.allocator, .ctx = ctx, .idx = i };

        switch (p.kind) {
            .float => {
                const adj = c.gtk_adjustment_new(
                    currentFloat(win, p),
                    p.min,
                    p.max,
                    p.step,
                    p.step * 10.0,
                    0,
                );
                const scale = c.gtk_scale_new(c.GTK_ORIENTATION_HORIZONTAL, adj);
                c.gtk_widget_set_size_request(scale, 220, -1);
                c.gtk_widget_set_valign(scale, c.GTK_ALIGN_CENTER);
                c.gtk_scale_set_draw_value(@ptrCast(@alignCast(scale)), 1);
                c.gtk_scale_set_digits(@ptrCast(@alignCast(scale)), digitsForStep(p.step));
                _ = c.g_signal_connect_data(
                    adj,
                    "value-changed",
                    @ptrCast(&onSliderChanged),
                    @ptrCast(rctx),
                    @ptrCast(&freeRowCtx),
                    c.G_CONNECT_DEFAULT,
                );
                c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), scale);
            },
            .color => {
                const dlg = c.gtk_color_dialog_new();
                const btn = c.gtk_color_dialog_button_new(dlg);
                c.gtk_widget_set_valign(btn, c.GTK_ALIGN_CENTER);
                const cur = currentColor(win, p);
                var rgba: c.GdkRGBA = .{ .red = cur[0], .green = cur[1], .blue = cur[2], .alpha = 1.0 };
                c.gtk_color_dialog_button_set_rgba(@ptrCast(@alignCast(btn)), &rgba);
                _ = c.g_signal_connect_data(
                    btn,
                    "notify::rgba",
                    @ptrCast(&onColorChanged),
                    @ptrCast(rctx),
                    @ptrCast(&freeRowCtx),
                    c.G_CONNECT_DEFAULT,
                );
                c.adw_action_row_add_suffix(@ptrCast(@alignCast(row)), btn);
            },
        }
        c.adw_preferences_group_add(@ptrCast(@alignCast(group)), @ptrCast(@alignCast(row)));
    }

    // Reset row — pushes every param back to the shader's defaults.
    if (ctx.params_len > 0) {
        const reset_row = c.adw_action_row_new();
        c.adw_preferences_row_set_title(@ptrCast(@alignCast(reset_row)), "Reset to shader defaults");
        const reset_btn = c.gtk_button_new_with_label("Reset");
        c.gtk_widget_set_valign(reset_btn, c.GTK_ALIGN_CENTER);
        const rst = win.allocator.create(RowCtx) catch null;
        if (rst) |r| {
            r.* = .{ .allocator = win.allocator, .ctx = ctx, .idx = 0 };
            _ = c.g_signal_connect_data(
                reset_btn,
                "clicked",
                @ptrCast(&onResetClicked),
                @ptrCast(r),
                @ptrCast(&freeRowCtx),
                c.G_CONNECT_DEFAULT,
            );
        }
        c.adw_action_row_add_suffix(@ptrCast(@alignCast(reset_row)), reset_btn);
        c.adw_preferences_group_add(@ptrCast(@alignCast(group)), @ptrCast(@alignCast(reset_row)));
    }

    c.adw_preferences_page_add(@ptrCast(@alignCast(page)), @ptrCast(@alignCast(group)));
    c.adw_preferences_dialog_add(@ptrCast(@alignCast(dialog)), @ptrCast(@alignCast(page)));

    // Free the Ctx once the dialog goes away (row ctxs free via
    // their own GDestroyNotify and only borrow Ctx).
    _ = c.g_signal_connect_data(
        dialog,
        "closed",
        @ptrCast(&onDialogClosed),
        @ptrCast(ctx),
        null,
        c.G_CONNECT_DEFAULT,
    );

    c.adw_dialog_present(@ptrCast(@alignCast(dialog)), @ptrCast(win.app_window));
    return true;
}

fn dupZ(allocator: std.mem.Allocator, s: []const u8) ?[:0]u8 {
    return allocator.dupeZ(u8, s) catch null;
}

fn digitsForStep(step: f32) c_int {
    if (step >= 1.0) return 0;
    if (step >= 0.1) return 1;
    if (step >= 0.01) return 2;
    return 3;
}

/// Current effective value: config override else shader default.
fn currentFloat(win: *Window, p: *const shader_pass.Param) f64 {
    for (win.config.shader_params.items) |kv| {
        if (std.mem.eql(u8, kv.name, p.name()) and kv.color == null) return kv.value;
    }
    return p.default_value;
}

fn currentColor(win: *Window, p: *const shader_pass.Param) [3]f32 {
    for (win.config.shader_params.items) |kv| {
        if (std.mem.eql(u8, kv.name, p.name())) {
            if (kv.color) |col| return col;
        }
    }
    return p.default_color;
}

fn onSliderChanged(adj: *c.GtkAdjustment, user: ?*anyopaque) callconv(.c) void {
    const rctx = cast.userData(RowCtx, user);
    const p = &rctx.ctx.params[rctx.idx];
    const v: f32 = @floatCast(c.gtk_adjustment_get_value(adj));
    rctx.ctx.win.setShaderParam(p.name(), v, null);
}

fn onColorChanged(btn: *c.GtkColorDialogButton, _: *c.GParamSpec, user: ?*anyopaque) callconv(.c) void {
    const rctx = cast.userData(RowCtx, user);
    const p = &rctx.ctx.params[rctx.idx];
    const rgba = c.gtk_color_dialog_button_get_rgba(btn);
    rctx.ctx.win.setShaderParam(p.name(), 0, .{ rgba.*.red, rgba.*.green, rgba.*.blue });
}

fn onResetClicked(_: *c.GtkButton, user: ?*anyopaque) callconv(.c) void {
    const rctx = cast.userData(RowCtx, user);
    const ctx = rctx.ctx;
    for (ctx.params[0..ctx.params_len]) |*p| {
        switch (p.kind) {
            .float => ctx.win.setShaderParam(p.name(), p.default_value, null),
            .color => ctx.win.setShaderParam(p.name(), 0, p.default_color),
        }
    }
}

fn freeRowCtx(user: ?*anyopaque) callconv(.c) void {
    if (user) |u| {
        const rctx: *RowCtx = @ptrCast(@alignCast(u));
        rctx.allocator.destroy(rctx);
    }
}

fn onDialogClosed(_: *c.AdwDialog, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    ctx.allocator.destroy(ctx);
}
