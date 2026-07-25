//! The keeper child of an external display session (`--keep`).
//!
//! A display session needs a PTY child so nothing in the session
//! machinery is special-cased, but there is no application to run: the
//! rendering process lives outside sketerm entirely. The keeper just
//! holds the PTY open until the session is torn down.
//!
//! It is spawned as the DAEMON'S OWN BINARY (`/proc/self/exe --keep`):
//! a client cannot know the daemon host's binary path, and a mismatched
//! build would exit instantly and take the session with it. The
//! consequence is that ANY process hosting a Daemon must answer
//! `--keep` — which is why this lives in a shared module the smoke rigs
//! (whose binaries host a daemon in-process) dispatch to as well.

const std = @import("std");
const c = @import("../c.zig").c;

/// True when `argv` asks for keeper mode. Call this FIRST in any main
/// that may host a daemon.
pub fn wanted(argv: []const [*:0]const u8) bool {
    for (argv[@min(argv.len, 1)..]) |a| {
        if (std.mem.eql(u8, std.mem.span(a), "--keep")) return true;
    }
    return false;
}

/// Block until stdin closes, discarding everything. Reading matters:
/// an interactive program on the same display may well write to this
/// PTY, and a keeper that let the buffer fill would stall the session.
pub fn serve() u8 {
    const banner = "sketerm display session (external renderer); no application launched by sketerm\r\n";
    _ = c.write(1, banner.ptr, banner.len);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(0, &buf, buf.len);
        if (n == 0) return 0; // EOF: the session is being torn down
        if (n < 0 and std.posix.errno(n) != .INTR) return 0;
    }
}

test "keep: --keep is recognised anywhere after argv[0]" {
    const t = std.testing;
    try t.expect(wanted(&[_][*:0]const u8{ "sketerm-mux", "--keep" }));
    try t.expect(wanted(&[_][*:0]const u8{ "sketerm-mux", "--socket", "/x", "--keep" }));
    try t.expect(!wanted(&[_][*:0]const u8{"sketerm-mux"}));
    try t.expect(!wanted(&[_][*:0]const u8{}));
    // argv[0] is never a flag, even if a binary is named that way.
    try t.expect(!wanted(&[_][*:0]const u8{"--keep"}));
}
