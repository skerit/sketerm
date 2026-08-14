//! Public mux-client SDK root: the supported surface for OUT-OF-REPO
//! clients of the sketerm-mux daemon (harnesses, automation), exported
//! by build.zig as the `mux-client` module.
//!
//! Everything reachable from here must stay on the lean core dep set
//! (libc + core cbindings, no GTK/GLib) — `zig build mux-client-check`
//! compiles this graph standalone and is the guard.

pub const wire = @import("mux/wire.zig");
/// The libc surface the SDK itself is built against (the lean core
/// binding set — no GTK). Exposed because Zig 0.16's std removed the
/// posix socket/file wrappers, so consumers need libc anyway and this
/// saves each one its own TranslateC setup.
pub const c = @import("c.zig").c;
pub const platform = @import("util/platform.zig");
pub const client = @import("mux/client.zig");
pub const sockpath = @import("mux/sockpath.zig");
pub const snapshot = @import("mux/snapshot.zig");
