// Tiny helpers for pointer casts that recur across the GTK UI layer.

const std = @import("std");
const c = @import("../c.zig").c;

/// Cast a GTK/GLib opaque user-data pointer back to its concrete
/// type. Performs the @alignCast + @ptrCast in one call so the
/// callback prologues across the UI layer stay short.
pub inline fn userData(comptime T: type, user: ?*anyopaque) *T {
    return @ptrCast(@alignCast(user.?));
}

/// A GClosureNotify-shaped destroy callback that frees a heap-allocated
/// `*T` via its `allocator` field. Use for the common "context owns only
/// itself" case (`g_signal_connect_data`'s 5th arg); write a custom free
/// fn when the context also owns slices that need freeing first.
pub fn destroyCtx(comptime T: type) *const fn (?*anyopaque) callconv(.c) void {
    return &struct {
        fn f(user: ?*anyopaque) callconv(.c) void {
            if (user) |u| {
                const ctx: *T = @ptrCast(@alignCast(u));
                ctx.allocator.destroy(ctx);
            }
        }
    }.f;
}

/// The text of a GtkEditable (entry/row) as a Zig slice; empty if unset.
pub fn editableText(widget: anytype) [:0]const u8 {
    const txt = c.gtk_editable_get_text(@ptrCast(@alignCast(widget)));
    if (txt == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
}

/// Copy `s` into a fresh NUL-terminated stack buffer of capacity `N` for
/// passing to a GTK `set_text`; truncates if `s` exceeds `N`.
pub fn sliceToZ(comptime N: usize, s: []const u8) [N:0]u8 {
    var z: [N:0]u8 = undefined;
    const n = @min(s.len, N);
    @memcpy(z[0..n], s[0..n]);
    z[n] = 0;
    return z;
}
