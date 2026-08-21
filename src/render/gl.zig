//! Minimal GL helpers — shader compilation + program linking.
//!
//! GLSL version portability: shader sources in src/render/ carry NO
//! `#version` / `precision` lines — compileShader prepends a header
//! for the active API. Linux GTK contexts are GLES 3.0 (`300 es`);
//! macOS GDK is desktop-GL-only (4.1 core via CGL), where the same
//! bodies compile as `330 core`. `api` is set from the realized
//! GdkGLContext (Pane.onRealize) and defaults per-OS so headless
//! tools work without a GTK context.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("../c.zig").c;

pub const Api = enum { gles, gl_core };

/// Process-wide: every context in the share group has the same API.
pub var api: Api = if (builtin.os.tag == .macos) .gl_core else .gles;

/// Version + default-precision preamble for the active API.
/// Desktop GLSL 1.30+ accepts (and ignores) float/int precision
/// qualifiers but NOT default-precision statements for sampler
/// types, so those live only in the ES header.
pub fn shaderHeader(stage: c_uint) []const u8 {
    return switch (api) {
        .gles => if (stage == c.GL_FRAGMENT_SHADER)
            "#version 300 es\nprecision highp float;\nprecision mediump sampler2DArray;\n#line 0\n"
        else
            "#version 300 es\n#line 0\n",
        .gl_core => "#version 330 core\n#line 0\n",
    };
}

/// Configure a GtkGLArea for the platform's GL API. Linux keeps the
/// historical GLES request; macOS GDK is desktop-GL-only and FAILS
/// realize (black widget) when restricted to GLES, so it gets GL.
pub fn requestArea(area: *c.GtkGLArea) void {
    if (builtin.os.tag == .macos) {
        c.gtk_gl_area_set_allowed_apis(area, @intCast(c.GDK_GL_API_GL));
    } else {
        c.gtk_gl_area_set_use_es(area, 1);
    }
}

/// Sync `api` with what GDK actually realized for this area — call
/// after make_current in a realize handler. No-op when the context
/// is unavailable (error state).
pub fn adoptAreaApi(area: *c.GtkGLArea) void {
    const ctx = c.gtk_gl_area_get_context(area) orelse return;
    const got: c_int = @intCast(c.gdk_gl_context_get_api(ctx));
    api = if (got == c.GDK_GL_API_GL) .gl_core else .gles;
}

pub const ShaderError = error{
    CompileFailed,
    LinkFailed,
};

pub fn compileShader(stage: c_uint, source: []const u8) !c_uint {
    const sh = c.glCreateShader(stage);
    if (sh == 0) return error.CompileFailed;
    const header = shaderHeader(stage);
    const ptrs = [2]?[*]const u8{ header.ptr, source.ptr };
    const lens = [2]c_int{ @intCast(header.len), @intCast(source.len) };
    c.glShaderSource(sh, 2, @ptrCast(&ptrs), &lens);
    c.glCompileShader(sh);

    var ok: c_int = 0;
    c.glGetShaderiv(sh, c.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var log_buf: [2048]u8 = undefined;
        var log_len: c_int = 0;
        c.glGetShaderInfoLog(sh, @intCast(log_buf.len), &log_len, &log_buf);
        std.debug.print("shader compile failed:\n{s}\n", .{log_buf[0..@intCast(log_len)]});
        c.glDeleteShader(sh);
        return error.CompileFailed;
    }
    return sh;
}

pub fn linkProgram(vs: c_uint, fs: c_uint) !c_uint {
    const prog = c.glCreateProgram();
    if (prog == 0) return error.LinkFailed;
    c.glAttachShader(prog, vs);
    c.glAttachShader(prog, fs);
    c.glLinkProgram(prog);

    var ok: c_int = 0;
    c.glGetProgramiv(prog, c.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log_buf: [2048]u8 = undefined;
        var log_len: c_int = 0;
        c.glGetProgramInfoLog(prog, @intCast(log_buf.len), &log_len, &log_buf);
        std.debug.print("program link failed:\n{s}\n", .{log_buf[0..@intCast(log_len)]});
        c.glDeleteProgram(prog);
        return error.LinkFailed;
    }
    return prog;
}

pub fn buildProgram(vs_src: []const u8, fs_src: []const u8) !c_uint {
    const vs = try compileShader(c.GL_VERTEX_SHADER, vs_src);
    defer c.glDeleteShader(vs);
    const fs = try compileShader(c.GL_FRAGMENT_SHADER, fs_src);
    defer c.glDeleteShader(fs);
    return try linkProgram(vs, fs);
}

// ---- owned-resource lifetime helpers --------------------------------
//
// Every render pass follows the same contract (see CLAUDE.md):
//   forgetGL  - zero the cached ids WITHOUT GL calls. The context that
//               owned them is gone (reparenting unrealizes the
//               GtkGLArea and destroys its GdkGLContext); non-zero
//               cached ids from a dead context render silent black.
//   releaseGL - glDelete* every owned resource, then forget. Caller
//               must have a current GL context - the pane's unrealize
//               signal is the last opportunity. Without this, every
//               closed pane leaks its programs/VAOs/VBOs/textures into
//               the window's shared context.
// The helpers below are the shared vocabulary those two entry points
// are written in; the per-pass forgetGL additionally resets the pass's
// own non-GL caches (uniform locations, dirty flags, generations).

/// glDeleteProgram then zero; skips id 0 (never realized / forgotten).
pub fn deleteProgram(id: *c_uint) void {
    if (id.* == 0) return;
    c.glDeleteProgram(id.*);
    id.* = 0;
}

/// glDeleteVertexArrays(1) then zero; skips id 0.
pub fn deleteVertexArray(id: *c_uint) void {
    if (id.* == 0) return;
    c.glDeleteVertexArrays(1, id);
    id.* = 0;
}

/// glDeleteBuffers(1) then zero; skips id 0.
pub fn deleteBuffer(id: *c_uint) void {
    if (id.* == 0) return;
    c.glDeleteBuffers(1, id);
    id.* = 0;
}

/// glDeleteTextures(1) then zero; skips id 0.
pub fn deleteTexture(id: *c_uint) void {
    if (id.* == 0) return;
    c.glDeleteTextures(1, id);
    id.* = 0;
}

/// glDeleteFramebuffers(1) then zero; skips id 0.
pub fn deleteFramebuffer(id: *c_uint) void {
    if (id.* == 0) return;
    c.glDeleteFramebuffers(1, id);
    id.* = 0;
}

/// One vertex attribute in an interleaved buffer, all-float.
pub const Attrib = struct {
    name: [:0]const u8,
    off: usize = 0,
    count: c_int,
};

/// (Re)set vertex attribute pointers for `fields` against the
/// currently-bound VBO. Must be called at realize-time AND every time
/// the underlying VBO is recreated: a VAO records buffer names per
/// attribute, so recreating a VBO without re-binding leaves attributes
/// pointing at the freed buffer and SIGSEGVs on draw. `instanced`
/// additionally sets a divisor of 1 on every attribute (one value per
/// instance rather than per vertex). Attributes the linker optimized
/// out (loc < 0) are skipped.
pub fn bindAttribs(program: c_uint, stride: c_int, fields: []const Attrib, instanced: bool) void {
    for (fields) |f| {
        const loc = c.glGetAttribLocation(program, f.name.ptr);
        if (loc < 0) continue;
        const idx: c_uint = @intCast(loc);
        c.glEnableVertexAttribArray(idx);
        c.glVertexAttribPointer(idx, f.count, c.GL_FLOAT, c.GL_FALSE, stride, @ptrFromInt(f.off));
        if (instanced) c.glVertexAttribDivisor(idx, 1);
    }
}

/// Three rotating VAO/VBO pairs for streamed instance uploads.
///
/// Frame N writes to (and draws from) slot (N mod 3); the next frame
/// advances. By the time the CPU cycles back to a slot, the GPU
/// finished reading it ~3 frames ago, so re-filling it never hits
/// Mesa's implicit CPU<->GPU sync on buffer reuse. The single-VBO
/// orphan-and-upload alternative was stalling the main thread 5-8 ms
/// per frame during heavy htop activity (freezing GTK chrome dispatch
/// on the same surface). Kitty / Alacritty use the same approach.
/// Each VAO records its OWN VBO binding for vertex attributes, so
/// `realize` configures each VAO once and draw just binds `vao()` -
/// no per-frame attrib re-binding.
pub const TripleBuf = struct {
    vaos: [3]c_uint = .{ 0, 0, 0 },
    vbos: [3]c_uint = .{ 0, 0, 0 },
    /// Allocated storage size per slot, in bytes. Tracked separately
    /// so the first visit to each slot does an actual `glBufferData`
    /// (allocate) and subsequent visits use map+invalidate (reuse).
    caps: [3]usize = .{ 0, 0, 0 },
    /// Slot used by the most recent upload + draw. The next `upload`
    /// advances to `(slot + 1) % 3` before writing.
    slot: u8 = 0,

    /// Generate the three pairs and record `fields` (instanced, one
    /// value per instance) into each VAO. Needs a current GL context
    /// and a linked `program`. Leaves VAO 0 bound.
    pub fn realize(self: *TripleBuf, program: c_uint, stride: c_int, fields: []const Attrib) void {
        c.glGenVertexArrays(3, &self.vaos[0]);
        c.glGenBuffers(3, &self.vbos[0]);
        for (0..3) |i| {
            c.glBindVertexArray(self.vaos[i]);
            c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbos[i]);
            bindAttribs(program, stride, fields, true);
        }
        c.glBindVertexArray(0);
    }

    /// Drop the ids without GL calls - the owning context is gone.
    pub fn forget(self: *TripleBuf) void {
        @memset(&self.vaos, 0);
        @memset(&self.vbos, 0);
        @memset(&self.caps, 0);
        self.slot = 0;
    }

    /// glDelete the 3 VAOs + 3 VBOs (flat arrays - glDelete*
    /// tolerates id == 0, so the whole array can be passed), then
    /// forget. Caller must have a current GL context.
    pub fn release(self: *TripleBuf) void {
        c.glDeleteVertexArrays(3, &self.vaos[0]);
        c.glDeleteBuffers(3, &self.vbos[0]);
        self.forget();
    }

    /// The VAO matching the slot the most recent upload wrote.
    pub fn vao(self: *const TripleBuf) c_uint {
        return self.vaos[self.slot];
    }

    /// Advance to the next slot and stream `bytes` into it. Returns
    /// false (nothing uploaded, slot not advanced) when unrealized or
    /// `bytes` is empty.
    pub fn upload(self: *TripleBuf, bytes: []const u8) bool {
        if (self.vbos[0] == 0 or bytes.len == 0) return false;

        // Advance to the next slot. With 3 slots and our render rate,
        // the GPU is long done with whatever was in this slot.
        self.slot = (self.slot + 1) % 3;
        const slot: usize = self.slot;

        c.glBindBuffer(c.GL_ARRAY_BUFFER, self.vbos[slot]);

        // Allocate storage on the very first visit to each slot -
        // subsequent calls reuse it via map+invalidate.
        if (self.caps[slot] < bytes.len) {
            c.glBufferData(c.GL_ARRAY_BUFFER, @intCast(bytes.len), null, c.GL_STREAM_DRAW);
            self.caps[slot] = bytes.len;
        }

        // glMapBufferRange + INVALIDATE_BUFFER_BIT + UNSYNCHRONIZED_BIT
        // is the documented fastest streaming-upload path. INVALIDATE
        // tells the driver we don't need the existing contents (so it
        // won't preserve them); UNSYNCHRONIZED tells it not to wait
        // for pending GPU work referencing the buffer (we guarantee
        // that with the slot rotation above). With both flags Mesa
        // hands us a fresh memory region without any client-server
        // round-trip.
        const flags: c.GLbitfield = c.GL_MAP_WRITE_BIT |
            c.GL_MAP_INVALIDATE_BUFFER_BIT |
            c.GL_MAP_UNSYNCHRONIZED_BIT;
        const ptr_raw = c.glMapBufferRange(c.GL_ARRAY_BUFFER, 0, @intCast(bytes.len), flags);
        if (ptr_raw != null) {
            const dst: [*]u8 = @ptrCast(ptr_raw);
            @memcpy(dst[0..bytes.len], bytes);
            _ = c.glUnmapBuffer(c.GL_ARRAY_BUFFER);
        } else {
            // Fallback if mapping fails for any reason - full re-upload.
            c.glBufferData(
                c.GL_ARRAY_BUFFER,
                @intCast(bytes.len),
                bytes.ptr,
                c.GL_STREAM_DRAW,
            );
        }
        return true;
    }
};
