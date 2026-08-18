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
/// The monotonic millisecond clock every deadline in this SDK is
/// measured against (`nowMs`).
pub const clock = @import("util/clock.zig");
/// Interrupt a blocking socket from another thread: publish a
/// duplicate, stop it, release it — the slot `client`'s panel-requester
/// connect helpers take.
pub const fdcancel = @import("util/fdcancel.zig");
pub const client = @import("mux/client.zig");
pub const channel_pump = @import("mux/channel_pump.zig");
pub const sockpath = @import("mux/sockpath.zig");
pub const snapshot = @import("mux/snapshot.zig");
/// Panel RPC command/reply schemas and validation, including reliable event
/// epoch identity and relay-only exact-session opening.
pub const panelrpc = @import("mux/panelrpc.zig");
/// The declarative A2UI panel document model (pure Zig + libc, no
/// GTK): out-of-repo panel authors validate against the REAL parser
/// instead of guessing at the vocabulary.
pub const paneldoc = @import("ui/panel/doc.zig");
