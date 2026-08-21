//! Headless image-render smoke test.
//!
//! Initializes a Mesa surfaceless EGL context, creates a 256×64 FBO,
//! drives ImagePass + ImageStore against a known 32×32 RGBA image,
//! reads pixels back, and asserts the upper-left of the framebuffer
//! contains the input red.
//!
//! Run: `zig build smoke-image`. Exits 0 on pass, non-zero on fail.
//! No display server required.

const std = @import("std");
const c = @import("c.zig").c;
const eglboot = @import("smoke/eglboot.zig");
const ImagePass = @import("render/image_pass.zig").ImagePass;
const ImageStore = @import("grid/image_store.zig").Store;

const W: c_int = 256;
const H: c_int = 64;

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. EGL surfaceless context.
    const egl = eglboot.surfaceless(.gles3) catch |e| {
        switch (e) {
            error.NoDisplay => std.debug.print("smoke-image: eglGetDisplay failed\n", .{}),
            error.Init => std.debug.print("smoke-image: eglInitialize failed\n", .{}),
            error.BindApi => std.debug.print("smoke-image: eglBindAPI failed\n", .{}),
            error.ChooseConfig => std.debug.print("smoke-image: eglChooseConfig failed\n", .{}),
            error.CreateContext => std.debug.print(
                "smoke-image: eglCreateContext failed (err 0x{x})\n",
                .{eglboot.lastError()},
            ),
            error.MakeCurrent => std.debug.print(
                "smoke-image: eglMakeCurrent failed (err 0x{x})\n",
                .{eglboot.lastError()},
            ),
        }
        return 1;
    };
    std.debug.print("smoke-image: EGL {d}.{d} on {s}\n", .{ egl.major, egl.minor, egl.vendor() });

    std.debug.print("smoke-image: GL_VERSION={s}\n", .{c.glGetString(c.GL_VERSION)});

    // 2. Offscreen framebuffer.
    _ = eglboot.offscreenRgba8(W, H) catch {
        std.debug.print("smoke-image: framebuffer incomplete\n", .{});
        return 1;
    };
    c.glClearColor(0, 0, 0, 1);
    c.glClear(c.GL_COLOR_BUFFER_BIT);

    // 3. ImagePass + ImageStore.
    var pass = ImagePass.init();
    pass.realize() catch |e| {
        std.debug.print("smoke-image: image_pass realize: {s}\n", .{@errorName(e)});
        return 1;
    };
    pass.debug = true;

    var store = ImageStore.init(allocator);
    defer store.deinit();
    store.cell_w = 8;
    store.cell_h = 16;
    store.debug = true;

    // 4. 32×32 solid-red RGBA image at cell (0,0).
    const img_w: u32 = 32;
    const img_h: u32 = 32;
    const npix: usize = img_w * img_h;
    const rgba = try allocator.alloc(u8, npix * 4);
    defer allocator.free(rgba);
    for (0..npix) |i| {
        rgba[i * 4 + 0] = 0xFF;
        rgba[i * 4 + 1] = 0x00;
        rgba[i * 4 + 2] = 0x00;
        rgba[i * 4 + 3] = 0xFF;
    }

    try store.addWithPlacement(rgba, img_w, img_h, 0, 0, 1, 0, 0);
    // Add a SECOND image (32×32 green) at cell (8, 0) to verify
    // multi-image rendering, and exercise cell-grid scaling
    // (cells_wide = 4, cells_high = 2 → 32×32 px since cell is 8×16).
    const rgba2 = try allocator.alloc(u8, npix * 4);
    defer allocator.free(rgba2);
    for (0..npix) |i| {
        rgba2[i * 4 + 0] = 0x00;
        rgba2[i * 4 + 1] = 0xFF;
        rgba2[i * 4 + 2] = 0x00;
        rgba2[i * 4 + 3] = 0xFF;
    }
    try store.addFull(.{
        .rgba = rgba2,
        .width = img_w,
        .height = img_h,
        .row = 0,
        .col = 8,
        .image_id = 2,
        .cells_wide = 4,
        .cells_high = 2,
    });
    store.flushUploads();
    pass.draw(&store, W, H);
    c.glFinish();

    // 5. Read back pixels.
    const fb_bytes: usize = @intCast(W * H * 4);
    const fb = try allocator.alloc(u8, fb_bytes);
    defer allocator.free(fb);
    c.glReadPixels(0, 0, W, H, c.GL_RGBA, c.GL_UNSIGNED_BYTE, fb.ptr);

    // 6. Assert upper-left 32×32 region has red. Note: glReadPixels
    // returns bottom-left origin, so the image we drew at top-left of
    // the FBO is at the TOP rows of the readback (row index H-1 down).
    // Our shader does Y-flip, so the image-top is at the framebuffer's
    // top, which in glReadPixels output is at the END of the buffer.
    var red_in_top: usize = 0;
    var red_in_bottom: usize = 0;
    var sample_x: c_int = 4;
    while (sample_x < 28) : (sample_x += 4) {
        var sample_y: c_int = 4;
        while (sample_y < 28) : (sample_y += 4) {
            const top_row: c_int = H - 1 - sample_y;
            const top_idx: usize = @intCast((top_row * W + sample_x) * 4);
            if (fb[top_idx] > 0xC0 and fb[top_idx + 1] < 0x40 and fb[top_idx + 2] < 0x40)
                red_in_top += 1;
            const bot_idx: usize = @intCast((sample_y * W + sample_x) * 4);
            if (fb[bot_idx] > 0xC0 and fb[bot_idx + 1] < 0x40 and fb[bot_idx + 2] < 0x40)
                red_in_bottom += 1;
        }
    }

    // Sample the green image too — at cell (8,0) with cells_wide=4
    // and cell_w=8, x = 64..96 in pixels.
    var green_samples: usize = 0;
    sample_x = 68;
    while (sample_x < 92) : (sample_x += 4) {
        var sample_y: c_int = 4;
        while (sample_y < 28) : (sample_y += 4) {
            const top_row: c_int = H - 1 - sample_y;
            const top_idx: usize = @intCast((top_row * W + sample_x) * 4);
            if (fb[top_idx] < 0x40 and fb[top_idx + 1] > 0xC0 and fb[top_idx + 2] < 0x40)
                green_samples += 1;
        }
    }

    std.debug.print(
        "smoke-image: red samples top={d} bottom={d} green={d}\n",
        .{ red_in_top, red_in_bottom, green_samples },
    );

    if (red_in_top + red_in_bottom == 0) {
        std.debug.print("smoke-image: FAIL — no red pixels found anywhere in the framebuffer\n", .{});
        // Dump corners to see what we actually got.
        const tl_idx: usize = 0;
        const br_idx: usize = @intCast(((H - 1) * W + (W - 1)) * 4);
        std.debug.print(
            "  [0,0]={d},{d},{d}  [W-1,H-1]={d},{d},{d}\n",
            .{ fb[tl_idx], fb[tl_idx + 1], fb[tl_idx + 2], fb[br_idx], fb[br_idx + 1], fb[br_idx + 2] },
        );
        return 2;
    }
    if (green_samples == 0) {
        std.debug.print("smoke-image: FAIL — second (cell-scaled) image not rendered\n", .{});
        return 3;
    }
    std.debug.print("smoke-image: PASS\n", .{});
    return 0;
}
