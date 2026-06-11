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

const PREVIEW_W = 380;
const PREVIEW_H = 230;

const Ctx = struct {
    allocator: std.mem.Allocator,
    win: *Window,
    params: [shader_pass.MAX_PARAMS]shader_pass.Param = undefined,
    params_len: usize = 0,
    meta: shader_pass.Meta = .{},
    /// Live preview state. The shader source is OUR copy — the
    /// window/pane source can be swapped while the dialog is open.
    src_copy: ?[]u8 = null,
    preview_source: shader_pass.Source = .{},
    preview_pass: shader_pass.ShaderPass = .{},
    dummy_tex: c_uint = 0,
    epoch_us: i64 = 0,
    tick_id: c_uint = 0,
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
    ctx.src_copy = win.allocator.dupe(u8, src) catch null;
    if (ctx.src_copy) |sc| {
        ctx.preview_source = .{ .src = sc, .animate = true, .generation = 1 };
        ctx.preview_pass.source = &ctx.preview_source;
    }

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

    // Live preview: a GL area rendering a synthetic terminal frame
    // through THIS shader with the current values — sliders feed the
    // same overrides slice, so it updates as you drag (and animates,
    // so flicker/noise/persistence are visible too).
    if (ctx.src_copy != null) {
        const pgroup = c.adw_preferences_group_new();
        c.adw_preferences_group_set_title(@ptrCast(@alignCast(pgroup)), "Preview");
        const area = c.gtk_gl_area_new();
        c.gtk_gl_area_set_use_es(@ptrCast(area), 1);
        c.gtk_widget_set_size_request(area, PREVIEW_W, PREVIEW_H);
        c.gtk_widget_add_css_class(area, "card");
        _ = c.g_signal_connect_data(area, "realize", @ptrCast(&onPreviewRealize), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(area, "unrealize", @ptrCast(&onPreviewUnrealize), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        _ = c.g_signal_connect_data(area, "render", @ptrCast(&onPreviewRender), @ptrCast(ctx), null, c.G_CONNECT_DEFAULT);
        ctx.tick_id = c.gtk_widget_add_tick_callback(area, @ptrCast(&onPreviewTick), @ptrCast(ctx), null);
        c.adw_preferences_group_add(@ptrCast(@alignCast(pgroup)), area);
        c.adw_preferences_page_add(@ptrCast(@alignCast(page)), @ptrCast(@alignCast(pgroup)));
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
    // Defer the free past the destroy chain — the preview GLArea's
    // unrealize handler (GL cleanup) still needs the Ctx.
    _ = c.g_idle_add(@ptrCast(&deferredCtxFree), user);
}

fn deferredCtxFree(user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx = cast.userData(Ctx, user);
    if (ctx.src_copy) |s| ctx.allocator.free(s);
    ctx.allocator.destroy(ctx);
    return 0; // G_SOURCE_REMOVE
}

// ── Live preview ────────────────────────────────────────────────

/// Build a synthetic "terminal output" RGBA image: dark background,
/// colored glyph-block text lines, a prompt and a block cursor.
/// Deterministic (no RNG) so the preview is stable across opens.
fn makeDummyTerminal(allocator: std.mem.Allocator) ?[]u8 {
    const w = PREVIEW_W;
    const h = PREVIEW_H;
    const buf = allocator.alloc(u8, w * h * 4) catch return null;
    // Background.
    var i: usize = 0;
    while (i < buf.len) : (i += 4) {
        buf[i] = 13;
        buf[i + 1] = 13;
        buf[i + 2] = 18;
        buf[i + 3] = 255;
    }
    const colors = [_][3]u8{
        .{ 90, 220, 120 }, // green (prompt)
        .{ 230, 230, 230 }, // white
        .{ 200, 200, 200 }, // gray
        .{ 120, 170, 250 }, // blue
        .{ 240, 200, 90 }, // yellow
        .{ 235, 110, 100 }, // red
        .{ 200, 200, 200 },
        .{ 230, 230, 230 },
    };
    var seed: u32 = 0x5e1ec7ed;
    const line_h = 16;
    var row: usize = 0;
    while (row * line_h + 14 < h) : (row += 1) {
        const y0 = 4 + row * line_h;
        var x: usize = 6;
        // Prompt marker on every 4th line.
        const is_prompt = row % 4 == 0;
        var word: usize = 0;
        while (x + 10 < w - 6) : (word += 1) {
            seed = seed *% 1664525 +% 1013904223;
            const wlen = 2 + (seed >> 8) % 7;
            const color = if (is_prompt and word == 0)
                colors[0]
            else
                colors[(seed >> 16) % colors.len];
            var g: usize = 0;
            while (g < wlen and x + 7 < w - 6) : (g += 1) {
                // One 5x10 "glyph" block with a 2px gap.
                var py: usize = 0;
                while (py < 10) : (py += 1) {
                    var px: usize = 0;
                    while (px < 5) : (px += 1) {
                        // Flip vertically: GL texture row 0 = bottom.
                        const ty = h - 1 - (y0 + py + 2);
                        const off = (ty * w + x + px) * 4;
                        buf[off] = color[0];
                        buf[off + 1] = color[1];
                        buf[off + 2] = color[2];
                    }
                }
                x += 7;
            }
            x += 8; // word gap
            seed = seed *% 1664525 +% 1013904223;
            if ((seed >> 24) % 5 == 0) break; // short line
        }
    }
    // Block cursor on the last visible line.
    const cy = 4 + ((h - 18) / line_h) * line_h;
    var py: usize = 0;
    while (py < 12) : (py += 1) {
        var px: usize = 0;
        while (px < 8) : (px += 1) {
            const ty = h - 1 - (cy + py);
            const off = (ty * w + 10 + px) * 4;
            buf[off] = 230;
            buf[off + 1] = 230;
            buf[off + 2] = 230;
        }
    }
    return buf;
}

fn onPreviewRealize(area: *c.GtkGLArea, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    c.gtk_gl_area_make_current(area);
    if (c.gtk_gl_area_get_error(area) != null) return;
    const img = makeDummyTerminal(ctx.allocator) orelse return;
    defer ctx.allocator.free(img);
    c.glGenTextures(1, &ctx.dummy_tex);
    c.glBindTexture(c.GL_TEXTURE_2D, ctx.dummy_tex);
    c.glTexImage2D(c.GL_TEXTURE_2D, 0, c.GL_RGBA8, PREVIEW_W, PREVIEW_H, 0, c.GL_RGBA, c.GL_UNSIGNED_BYTE, img.ptr);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MIN_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_MAG_FILTER, c.GL_LINEAR);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_S, c.GL_CLAMP_TO_EDGE);
    c.glTexParameteri(c.GL_TEXTURE_2D, c.GL_TEXTURE_WRAP_T, c.GL_CLAMP_TO_EDGE);
}

fn onPreviewUnrealize(area: *c.GtkGLArea, user: ?*anyopaque) callconv(.c) void {
    const ctx = cast.userData(Ctx, user);
    c.gtk_gl_area_make_current(area);
    ctx.preview_pass.releaseGL();
    if (ctx.dummy_tex != 0) {
        var t = ctx.dummy_tex;
        c.glDeleteTextures(1, &t);
        ctx.dummy_tex = 0;
    }
}

fn onPreviewRender(area: *c.GtkGLArea, _: *c.GdkGLContext, user: ?*anyopaque) callconv(.c) c.gboolean {
    const ctx = cast.userData(Ctx, user);
    const w = c.gtk_widget_get_width(@ptrCast(area)) * c.gtk_widget_get_scale_factor(@ptrCast(area));
    const h = c.gtk_widget_get_height(@ptrCast(area)) * c.gtk_widget_get_scale_factor(@ptrCast(area));
    c.glViewport(0, 0, w, h);
    c.glClearColor(0.05, 0.05, 0.07, 1.0);
    c.glClear(c.GL_COLOR_BUFFER_BIT);
    if (ctx.dummy_tex == 0) return 1;

    // Live values: same slice setShaderParam mutates (re-read every
    // frame — appends can realloc it).
    ctx.preview_source.overrides = ctx.win.config.shader_params.items;

    const sp = &ctx.preview_pass;
    if (!sp.ensureProgram(ctx.allocator)) return 1;
    c.glGetIntegerv(c.GL_DRAW_FRAMEBUFFER_BINDING, &sp.prev_fbo);
    sp.tex = ctx.dummy_tex;
    const now = c.g_get_monotonic_time();
    if (ctx.epoch_us == 0) ctx.epoch_us = now;
    const t: f32 = @as(f32, @floatFromInt(now - ctx.epoch_us)) / 1e6;
    sp.finish(w, h, t);
    return 1;
}

fn onPreviewTick(area: *c.GtkWidget, _: *c.GdkFrameClock, _: ?*anyopaque) callconv(.c) c.gboolean {
    c.gtk_gl_area_queue_render(@ptrCast(area));
    return 1; // G_SOURCE_CONTINUE
}
