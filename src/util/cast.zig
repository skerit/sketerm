// Tiny helpers for pointer casts that recur across the GTK UI layer.

/// Cast a GTK/GLib opaque user-data pointer back to its concrete
/// type. Performs the @alignCast + @ptrCast in one call so the
/// callback prologues across the UI layer stay short.
pub inline fn userData(comptime T: type, user: ?*anyopaque) *T {
    return @ptrCast(@alignCast(user.?));
}
