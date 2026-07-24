const std = @import("std");
const c = @import("../c.zig").c;

/// Return the daemon account's configured login shell instead of its inherited environment hint.
pub fn accountLoginShell() []const u8 {
    if (c.getpwuid(c.geteuid())) |pw| {
        if (pw.*.pw_shell) |raw| {
            const shell = std.mem.span(raw);
            if (shell.len > 0) return shell;
        }
    }
    if (c.getenv("SHELL")) |raw| {
        const shell = std.mem.span(raw);
        if (shell.len > 0) return shell;
    }
    return "/bin/sh";
}

/// Account-shell launcher understood by old daemons that lack passwd lookup.
pub const remote_login_argv = [_][]const u8{
    "/bin/sh",
    "-c",
    \\shell=''
    \\if [ -n "${SKETERM_REMOTE_SHELL:-}" ] && [ -x "$SKETERM_REMOTE_SHELL" ]; then
    \\  shell=$SKETERM_REMOTE_SHELL
    \\elif command -v getent >/dev/null 2>&1; then
    \\  shell=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f7)
    \\elif command -v dscl >/dev/null 2>&1; then
    \\  shell=$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | cut -d' ' -f2-)
    \\fi
    \\if [ -z "$shell" ] || [ ! -x "$shell" ]; then shell=${SHELL:-/bin/sh}; fi
    \\if [ ! -x "$shell" ]; then shell=/bin/sh; fi
    \\login=${SKETERM_REMOTE_LOGIN:-1}
    \\unset SKETERM_REMOTE_SHELL
    \\unset SKETERM_REMOTE_LOGIN
    \\export SHELL="$shell"
    \\if [ "$login" = 0 ]; then exec "$shell"; fi
    \\exec "$shell" -l
};

test "remote login launcher resolves the account shell and execs it as login" {
    try std.testing.expectEqualStrings("/bin/sh", remote_login_argv[0]);
    try std.testing.expect(std.mem.indexOf(u8, remote_login_argv[2], "SKETERM_REMOTE_SHELL") != null);
    try std.testing.expect(std.mem.indexOf(u8, remote_login_argv[2], "SKETERM_REMOTE_LOGIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, remote_login_argv[2], "getent passwd") != null);
    try std.testing.expect(std.mem.indexOf(u8, remote_login_argv[2], "exec \"$shell\" -l") != null);
}

test "account login shell comes from passwd when available" {
    if (c.getpwuid(c.geteuid())) |pw| {
        if (pw.*.pw_shell) |raw| {
            const expected = std.mem.span(raw);
            if (expected.len > 0) try std.testing.expectEqualStrings(expected, accountLoginShell());
        }
    }
}
