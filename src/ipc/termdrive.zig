//! Headless terminal driver for the MCP server: a GTK-free mux client
//! that spawns and drives plain SHELL sessions on the (isolated)
//! daemon, maintaining a client-side Screen mirror from the snapshot +
//! event stream. This is the terminal counterpart of appdrive.zig —
//! it lets `sketerm mcp` run commands and read output with no GUI and
//! nothing of the user's reachable (each Term is a session on the
//! private daemon).

const std = @import("std");
const c = @import("../c.zig").c;
const muxclient = @import("../mux/client.zig");
const wire = @import("../mux/wire.zig");
const snapshot = @import("../mux/snapshot.zig");
const Event = @import("../parser/event.zig").Event;
const Screen = @import("../grid/screen.zig").Screen;
const Pool = @import("../grid/style_pool.zig").Pool;
const keys = @import("keys.zig");
const launch_cleanup = @import("launch_cleanup.zig");

const nowMs = @import("../util/clock.zig").nowMs;

pub const Error = error{
    SpawnFailed,
    NotConnected,
    Timeout,
    BadKey,
    OutOfMemory,
};

pub const CompletionSource = enum { none, shell_integration, process_tracking };

pub const CommandCompletion = struct {
    state: enum { unsupported, running, completed, unknown },
    exit_status: ?i32 = null,
    timed_out: bool = false,
    source: CompletionSource = .none,
};

pub const CommandToken = struct {
    completion_seq: u64,
};

/// Result of a sentinel-based exec (term_exec): structured completion
/// for commands run inside an EXISTING interactive shell, including
/// remote SSH sessions where OSC 133 integration cannot reach.
pub const ExecOutcome = struct {
    completed: bool,
    exit_status: ?i32 = null,
    timed_out: bool = false,
    /// Output between the sentinel markers (rendered lines; wrapped at
    /// the terminal width). When still pending, the output produced SO
    /// FAR (empty if the begin marker isn't visible, e.g. behind an
    /// alt-screen UI). Allocator-owned by the caller.
    output: []u8 = &.{},
    /// The begin marker scrolled out of the mirror's scrollback: the
    /// output is a TAIL, not the whole thing.
    truncated: bool = false,
    /// The terminal/shell itself died before the end marker.
    shell_died: bool = false,
    /// The command is still running and the tracker stays attached
    /// (term_exec_wait resumes it).
    pending: bool = false,
    /// The pending sentinel's nonce — the tracker id.
    tracker: ?[12]u8 = null,
    /// The alternate screen is active (full-screen dialog/TUI).
    alt_screen: bool = false,
    /// How long the terminal has produced no new output.
    idle_ms: i64 = 0,
    /// The output tail looks like a question/prompt (or an alt-screen
    /// UI is up): the command is probably WAITING FOR INPUT, not slow.
    interactive_hint: bool = false,
};

/// Prompt heuristic over the last non-empty output line: y/n style
/// questions, trailing ?/:, password asks, "press enter". Only a HINT
/// — the caller always ships the rendered screen alongside.
pub fn looksInteractive(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return false;
    var lower_buf: [256]u8 = undefined;
    const take = trimmed[trimmed.len - @min(trimmed.len, lower_buf.len) ..];
    const lower = std.ascii.lowerString(&lower_buf, take);
    const suffixes = [_][]const u8{ "[y/n]", "(y/n)", "[yes/no]", "(yes/no)", "yes/no?", "?", ":" };
    for (suffixes) |s| {
        if (std.mem.endsWith(u8, lower, s)) return true;
    }
    const anywhere = [_][]const u8{ "password", "passphrase", "press enter", "press any key", "press return" };
    for (anywhere) |s| {
        if (std.mem.indexOf(u8, lower, s) != null) return true;
    }
    return false;
}

test "looksInteractive" {
    const t = std.testing;
    try t.expect(looksInteractive("Do you want to continue? [Y/n] "));
    try t.expect(looksInteractive("Restart services during package upgrades without asking?"));
    try t.expect(looksInteractive("Enter passphrase for key '/home/x/.ssh/id_ed25519': "));
    try t.expect(looksInteractive("Press ENTER to continue"));
    try t.expect(!looksInteractive("Unpacking openjdk-17 (17.0.10) ..."));
    try t.expect(!looksInteractive("100%[==================>] 1.2M  --.-KB/s  in 0.1s"));
    try t.expect(!looksInteractive(""));
}

const ExecPending = struct {
    nonce: [12]u8,
};

/// Where a sentinel scan landed in the rendered text.
pub const SentinelParse = union(enum) {
    /// Not complete; begin_after = offset just past the begin marker
    /// when it is visible (output-so-far starts there).
    pending: struct { begin_after: ?usize },
    done: struct { status: i32, start: usize, end: usize, truncated: bool },
};

/// Build the one-line command that brackets `command` with echo-safe
/// sentinel markers.
///
/// subshell=true (the robust default): the script travels base64-
/// encoded and runs under a fresh `sh` from a temp file — DIALECT-
/// INDEPENDENT (works typed into fish/zsh/bash/dash sessions alike,
/// local or over SSH) and shell state stays out of the session. The
/// pipeline uses only syntax every shell family shares (`|`, `>`,
/// `&&`, `;`) and the script always exits 0, so an active `set -e` in
/// the session never kills it. The command itself travels INSIDE the
/// script via a quoted heredoc into a second temp file, so no process
/// command line ever contains it — ps/pgrep searches stay clean.
/// `shell` (null = "sh") runs the command file under a different
/// interpreter (e.g. bash for pipefail semantics) while the wrapper
/// stays plain sh.
///
/// subshell=false: the POSIX construction is typed directly so state
/// changes (cd/export/set) PERSIST in the session; needs a POSIX-ish
/// interactive shell (bash/zsh/dash — not fish). Marker strings are
/// quote-split in the typed text so the command echo can never be
/// mistaken for a marker; the `if` wrapper keeps a failing command
/// from tripping an active `set -e`.
pub fn buildExecLine(allocator: std.mem.Allocator, nonce: []const u8, command: []const u8, subshell: bool, noninteractive: bool, shell: ?[]const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    if (subshell) {
        // The command runs from a file under a CHILD interpreter, so
        // an `exit`/`exec` in the command can only leave the child —
        // the end marker always prints with the child's real status.
        // Package-manager safety net: the standard Debian/needrestart
        // frontends that would otherwise block on a dialog. Prefix
        // env on the child only — nothing leaks to the session.
        const env: []const u8 = if (noninteractive)
            "DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true APT_LISTCHANGES_FRONTEND=none NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 "
        else
            "";
        const interp = shell orelse "sh";
        const nl: []const u8 = if (command.len > 0 and command[command.len - 1] == '\n') "" else "\n";
        const script = try std.fmt.allocPrint(
            allocator,
            "cat > /tmp/.sk_{s}.c <<'SK_EOF_{s}'\n{s}{s}SK_EOF_{s}\nprintf '\\n%s\\n' SKB{s}\n{s}{s} /tmp/.sk_{s}.c\n__sk_s=$?\nprintf '\\n%s%d\\n' SKE{s}. \"$__sk_s\"\n",
            .{ nonce, nonce, command, nl, nonce, nonce, env, interp, nonce, nonce },
        );
        defer allocator.free(script);
        const enc = std.base64.standard.Encoder;
        const b64 = try allocator.alloc(u8, enc.calcSize(script.len));
        defer allocator.free(b64);
        _ = enc.encode(b64, script);
        try w.print("echo {s} | base64 -d > /tmp/.sk_{s} && sh /tmp/.sk_{s}; rm -f /tmp/.sk_{s} /tmp/.sk_{s}.c", .{ b64, nonce, nonce, nonce, nonce });
        return allocator.dupe(u8, aw.written());
    }
    try w.print("printf '\\n%s\\n' SKB''{s}; if {{ {s}\n}}; then __sk_s=0; else __sk_s=$?; fi; printf '\\n%s%d\\n' SKE''{s}. \"$__sk_s\"", .{ nonce, command, nonce });
    return allocator.dupe(u8, aw.written());
}

/// Scan rendered terminal text (scrollback + screen) for the LAST
/// begin marker and its matching end marker. Markers sit on their own
/// lines (printed after \n) so line-exact matching is safe from wrap.
pub fn findSentinel(text: []const u8, nonce: []const u8) SentinelParse {
    var begin_after: ?usize = null;
    var it = std.mem.splitScalar(u8, text, '\n');
    var off: usize = 0;
    var end_line_start: ?usize = null;
    var status: i32 = 0;
    while (it.next()) |line| {
        const line_start = off;
        off += line.len + 1;
        const trimmed = std.mem.trimEnd(u8, line, " \r");
        if (trimmed.len == 3 + nonce.len and std.mem.startsWith(u8, trimmed, "SKB") and
            std.mem.eql(u8, trimmed[3..], nonce))
        {
            begin_after = @min(off, text.len);
            end_line_start = null;
            continue;
        }
        if (trimmed.len > 4 + nonce.len and std.mem.startsWith(u8, trimmed, "SKE") and
            std.mem.eql(u8, trimmed[3 .. 3 + nonce.len], nonce) and trimmed[3 + nonce.len] == '.')
        {
            const digits = trimmed[4 + nonce.len ..];
            const st = std.fmt.parseInt(i32, digits, 10) catch continue;
            status = st;
            end_line_start = line_start;
        }
    }
    if (end_line_start) |endpos| {
        const truncated = begin_after == null or begin_after.? > endpos;
        const start = if (truncated) 0 else begin_after.?;
        return .{ .done = .{ .status = status, .start = start, .end = endpos, .truncated = truncated } };
    }
    return .{ .pending = .{ .begin_after = begin_after } };
}

/// Build the ssh forced-command that bootstraps OSC 133 shell
/// integration into a REMOTE login shell (term_open host sessions,
/// where the local spawn-time injection cannot reach).
///
/// The outer command uses only syntax every login-shell family parses
/// (fish/csh included: no quotes, no `$(...)`, no `${...}`) and the
/// real bootstrap travels base64-encoded, same transport as
/// buildExecLine. The bootstrap self-deletes, then re-execs the
/// user's $SHELL: bash via `--rcfile` (the rcfile emulates the login
/// profile chain a plain `ssh host` would have run, then sources the
/// integration), zsh via a temp ZDOTDIR (the shipped .zshenv shim,
/// which chains the user's own startup files), anything else plainly
/// with no integration — the session works either way. Needs `base64`
/// on the remote, like term_exec already does.
pub fn buildSshBootstrap(
    allocator: std.mem.Allocator,
    nonce: []const u8,
    bash_script: []const u8,
    zsh_env: []const u8,
    zsh_script: []const u8,
) ![]u8 {
    const script = try buildBootstrapScript(allocator, nonce, bash_script, zsh_env, zsh_script);
    defer allocator.free(script);
    const enc = std.base64.standard.Encoder;
    const b64 = try allocator.alloc(u8, enc.calcSize(script.len));
    defer allocator.free(b64);
    _ = enc.encode(b64, script);
    return std.fmt.allocPrint(
        allocator,
        "echo {s} | base64 -d >/tmp/.sk_ssh_{s} && sh /tmp/.sk_ssh_{s}",
        .{ b64, nonce, nonce },
    );
}

/// The inner bootstrap (plain `sh` script): resolve the account's
/// login shell (SKETERM_REMOTE_SHELL override → getent → dscl →
/// $SHELL, same ladder as mux/shell.zig's remote launcher — a
/// daemon-spawned session can't trust an inherited $SHELL), announce
/// it, and exec it with integration injected where supported. Shared
/// by both remote transports: base64-wrapped as an ssh forced command
/// (buildSshBootstrap), or passed VERBATIM as `sh -c` spawn argv on a
/// remote sketerm-mux daemon (nothing typed, nothing on the wire to
/// clean up).
pub fn buildBootstrapScript(
    allocator: std.mem.Allocator,
    nonce: []const u8,
    bash_script: []const u8,
    zsh_env: []const u8,
    zsh_script: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\rm -f /tmp/.sk_ssh_{s}
        \\d=`mktemp -d /tmp/.sketerm.XXXXXX 2>/dev/null` || {{ d=/tmp/.sketerm_{s}; mkdir -p "$d" && chmod 700 "$d" || exec sh -l; }}
        \\s=''
        \\if [ -n "${{SKETERM_REMOTE_SHELL:-}}" ] && [ -x "$SKETERM_REMOTE_SHELL" ]; then
        \\  s="$SKETERM_REMOTE_SHELL"
        \\elif command -v getent >/dev/null 2>&1; then
        \\  s=$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f7)
        \\elif command -v dscl >/dev/null 2>&1; then
        \\  s=$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | cut -d' ' -f2-)
        \\fi
        \\if [ -z "$s" ] || [ ! -x "$s" ]; then s="${{SHELL:-/bin/sh}}"; fi
        \\if [ ! -x "$s" ]; then s=/bin/sh; fi
        \\export SHELL="$s"
        \\case "${{s##*/}}" in
        \\bash)
        \\cat > "$d/rc.bash" <<'SK_RC_{s}'
        \\command rm -rf -- "${{SKETERM_REMOTE_TMP:?}}" 2>/dev/null
        \\unset SKETERM_REMOTE_TMP
        \\if ! shopt -q login_shell 2>/dev/null; then
        \\  [ -r /etc/profile ] && . /etc/profile
        \\  for __sk_f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
        \\    [ -r "$__sk_f" ] && {{ . "$__sk_f"; break; }}
        \\  done
        \\  unset __sk_f
        \\fi
        \\{s}
        \\SK_RC_{s}
        \\echo "[sketerm] remote shell: ${{s##*/}} (integration injected)"
        \\SKETERM_REMOTE_TMP="$d" TERM_PROGRAM=sketerm exec "$s" --rcfile "$d/rc.bash"
        \\;;
        \\zsh)
        \\cat > "$d/.zshenv" <<'SK_ZE_{s}'
        \\{s}
        \\SK_ZE_{s}
        \\cat > "$d/sketerm.zsh" <<'SK_ZI_{s}'
        \\{s}
        \\[ -n "$SKETERM_REMOTE_TMP" ] && command rm -rf -- "$SKETERM_REMOTE_TMP" 2>/dev/null
        \\unset SKETERM_REMOTE_TMP
        \\SK_ZI_{s}
        \\[ -n "$ZDOTDIR" ] && export SKETERM_ORIG_ZDOTDIR="$ZDOTDIR"
        \\echo "[sketerm] remote shell: ${{s##*/}} (integration injected)"
        \\ZDOTDIR="$d" SKETERM_SHELL_INTEGRATION="$d/sketerm.zsh" SKETERM_REMOTE_TMP="$d" TERM_PROGRAM=sketerm exec "$s" -l
        \\;;
        \\*)
        \\rm -rf "$d"
        \\echo "[sketerm] remote shell: ${{s##*/}} (no integration)"
        \\exec "$s" -l
        \\;;
        \\esac
        \\
    , .{ nonce, nonce, nonce, bash_script, nonce, nonce, zsh_env, nonce, nonce, zsh_script, nonce });
}

/// Read a whole file (bounded), libc IO like the rest of this module.
fn readScriptFile(allocator: std.mem.Allocator, path: []const u8) ?[]u8 {
    var pbuf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&pbuf, "{s}", .{path}) catch return null;
    const f = c.fopen(path_z.ptr, "rb") orelse return null;
    defer _ = c.fclose(f);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.fread(&buf, 1, buf.len, f);
        if (n == 0) break;
        out.appendSlice(allocator, buf[0..n]) catch {
            out.deinit(allocator);
            return null;
        };
        if (out.items.len > 256 * 1024) {
            out.deinit(allocator);
            return null;
        }
    }
    return out.toOwnedSlice(allocator) catch null;
}

fn buildBootstrapVia(allocator: std.mem.Allocator, comptime wrapped: bool) ?[]u8 {
    const shellintegration = @import("../util/shellintegration.zig");
    var base_buf: [4096]u8 = undefined;
    const base = shellintegration.baseDir(&base_buf) orelse return null;
    var raw: [6]u8 = undefined;
    if (c.getentropy(&raw, raw.len) != 0) return null;
    var nonce: [12]u8 = undefined;
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        nonce[i * 2] = hex[b >> 4];
        nonce[i * 2 + 1] = hex[b & 0xf];
    }
    var paths_buf: [4096]u8 = undefined;
    const bash_path = std.fmt.bufPrint(&paths_buf, "{s}/sketerm.bash", .{base}) catch return null;
    const bash_script = readScriptFile(allocator, bash_path) orelse return null;
    defer allocator.free(bash_script);
    const zsh_env_path = std.fmt.bufPrint(&paths_buf, "{s}/zsh/.zshenv", .{base}) catch return null;
    const zsh_env = readScriptFile(allocator, zsh_env_path) orelse return null;
    defer allocator.free(zsh_env);
    const zsh_path = std.fmt.bufPrint(&paths_buf, "{s}/sketerm.zsh", .{base}) catch return null;
    const zsh_script = readScriptFile(allocator, zsh_path) orelse return null;
    defer allocator.free(zsh_script);
    return if (wrapped)
        buildSshBootstrap(allocator, &nonce, bash_script, zsh_env, zsh_script) catch null
    else
        buildBootstrapScript(allocator, &nonce, bash_script, zsh_env, zsh_script) catch null;
}

/// Resolve the shipped integration scripts and build the remote
/// bootstrap command for an ssh term. Null when the script dir is
/// missing (feature unavailable) — the caller falls back to a plain
/// login shell, exactly the old behavior.
pub fn sshIntegrationCommand(allocator: std.mem.Allocator) ?[]u8 {
    return buildBootstrapVia(allocator, true);
}

/// Same resolution, but the INNER script — spawn argv material for a
/// remote sketerm-mux daemon (`sh -c <script>`).
pub fn integrationBootstrapScript(allocator: std.mem.Allocator) ?[]u8 {
    return buildBootstrapVia(allocator, false);
}

test "buildSshBootstrap ships a quote-free outer command and shell-cased bootstrap" {
    const t = std.testing;
    const boot = try buildSshBootstrap(t.allocator, "aabbccddeeff", "BASH_MARKER", "ZSHENV_MARKER", "ZSHRC_MARKER");
    defer t.allocator.free(boot);
    // The outer command is parsed by an UNKNOWN remote login shell
    // (could be fish/csh): no quotes, no $-expansion, no subshells.
    for (boot) |ch| {
        try t.expect(ch != '\'' and ch != '"' and ch != '$' and ch != '(' and ch != '{');
    }
    try t.expect(std.mem.startsWith(u8, boot, "echo "));
    try t.expect(std.mem.indexOf(u8, boot, "| base64 -d >/tmp/.sk_ssh_aabbccddeeff && sh /tmp/.sk_ssh_aabbccddeeff") != null);
    const b64 = boot["echo ".len..std.mem.indexOf(u8, boot, " |").?];
    const dec = std.base64.standard.Decoder;
    const buf = try t.allocator.alloc(u8, try dec.calcSizeForSlice(b64));
    defer t.allocator.free(buf);
    try dec.decode(buf, b64);
    // Self-deletes, cases on the login shell, embeds all three scripts.
    try t.expect(std.mem.startsWith(u8, buf, "rm -f /tmp/.sk_ssh_aabbccddeeff\n"));
    try t.expect(std.mem.indexOf(u8, buf, "case \"${s##*/}\" in") != null);
    try t.expect(std.mem.indexOf(u8, buf, "\nBASH_MARKER\n") != null);
    try t.expect(std.mem.indexOf(u8, buf, "\nZSHENV_MARKER\n") != null);
    try t.expect(std.mem.indexOf(u8, buf, "\nZSHRC_MARKER\n") != null);
    // bash: login-profile emulation + rcfile injection, TERM_PROGRAM
    // exported so the integration script's gate passes remotely.
    try t.expect(std.mem.indexOf(u8, buf, "exec \"$s\" --rcfile \"$d/rc.bash\"") != null);
    try t.expect(std.mem.indexOf(u8, buf, "TERM_PROGRAM=sketerm") != null);
    try t.expect(std.mem.indexOf(u8, buf, "shopt -q login_shell") != null);
    // zsh: temp ZDOTDIR carrying the shim, login shell preserved.
    try t.expect(std.mem.indexOf(u8, buf, "ZDOTDIR=\"$d\"") != null);
    // Unknown shells fall back to a plain login shell.
    try t.expect(std.mem.indexOf(u8, buf, "exec \"$s\" -l") != null);
    // Every arm announces the detected shell so term_open can report
    // it without a second tool call.
    try t.expect(std.mem.indexOf(u8, buf, "echo \"[sketerm] remote shell: ${s##*/} (integration injected)\"") != null);
    try t.expect(std.mem.indexOf(u8, buf, "echo \"[sketerm] remote shell: ${s##*/} (no integration)\"") != null);
    // Heredoc delimiters are nonce-suffixed so script content can
    // never terminate them early.
    try t.expect(std.mem.indexOf(u8, buf, "<<'SK_RC_aabbccddeeff'") != null);
    try t.expect(std.mem.indexOf(u8, buf, "<<'SK_ZE_aabbccddeeff'") != null);
    try t.expect(std.mem.indexOf(u8, buf, "<<'SK_ZI_aabbccddeeff'") != null);
}

test "sshIntegrationCommand resolves the dev-tree scripts" {
    const t = std.testing;
    // The dev tree ships the scripts next to the test binary's cwd
    // path resolution; when resolution fails (bare CI env) null is the
    // documented graceful answer.
    if (sshIntegrationCommand(t.allocator)) |cmd| {
        defer t.allocator.free(cmd);
        try t.expect(std.mem.startsWith(u8, cmd, "echo "));
        try t.expect(std.mem.indexOf(u8, cmd, "base64 -d") != null);
    }
}

test "buildExecLine wraps and quote-splits markers" {
    const t = std.testing;
    const line = try buildExecLine(t.allocator, "aabbccddeeff", "echo hi", false, false, null);
    defer t.allocator.free(line);
    // The typed text never contains a contiguous marker string.
    try t.expect(std.mem.indexOf(u8, line, "SKBaabbccddeeff") == null);
    try t.expect(std.mem.indexOf(u8, line, "SKB''aabbccddeeff") != null);
    try t.expect(std.mem.indexOf(u8, line, "{ echo hi\n}") != null);
    // Subshell mode: dialect-independent base64 → sh transport, and
    // the decoded script carries the plain markers + set -e guard.
    const sub = try buildExecLine(t.allocator, "aabbccddeeff", "cd /tmp && pwd", true, false, null);
    defer t.allocator.free(sub);
    try t.expect(std.mem.startsWith(u8, sub, "echo "));
    try t.expect(std.mem.indexOf(u8, sub, "| base64 -d > /tmp/.sk_aabbccddeeff && sh /tmp/.sk_aabbccddeeff; rm -f /tmp/.sk_aabbccddeeff /tmp/.sk_aabbccddeeff.c") != null);
    try t.expect(std.mem.indexOf(u8, sub, "SKBaabbccddeeff") == null); // only inside the b64 payload
    const b64 = sub["echo ".len..std.mem.indexOf(u8, sub, " |").?];
    const dec = std.base64.standard.Decoder;
    const buf = try t.allocator.alloc(u8, try dec.calcSizeForSlice(b64));
    defer t.allocator.free(buf);
    try dec.decode(buf, b64);
    try t.expect(std.mem.indexOf(u8, buf, "SKBaabbccddeeff") != null);
    // ps-safe: the command travels via a quoted heredoc into a file
    // and runs as `sh /tmp/.sk_<nonce>.c` — never on a command line.
    try t.expect(std.mem.indexOf(u8, buf, "cat > /tmp/.sk_aabbccddeeff.c <<'SK_EOF_aabbccddeeff'\ncd /tmp && pwd\nSK_EOF_aabbccddeeff") != null);
    try t.expect(std.mem.indexOf(u8, buf, "sh /tmp/.sk_aabbccddeeff.c\n__sk_s=$?") != null);
    try t.expect(std.mem.indexOf(u8, buf, "sh -c") == null);
    try t.expect(std.mem.indexOf(u8, buf, "SKEaabbccddeeff.") != null);
    // Quotes need no escaping at all now (heredoc transport).
    const q = try buildExecLine(t.allocator, "aabbccddeeff", "echo 'it''s' \"$HOME\"", true, false, null);
    defer t.allocator.free(q);
    const qb64 = q["echo ".len..std.mem.indexOf(u8, q, " |").?];
    const qbuf = try t.allocator.alloc(u8, try dec.calcSizeForSlice(qb64));
    defer t.allocator.free(qbuf);
    try dec.decode(qbuf, qb64);
    try t.expect(std.mem.indexOf(u8, qbuf, "\necho 'it''s' \"$HOME\"\nSK_EOF_") != null);
    // shell option swaps the command-file interpreter, not the wrapper.
    const bsh = try buildExecLine(t.allocator, "aabbccddeeff", "set -o pipefail; false | true", true, true, "bash");
    defer t.allocator.free(bsh);
    const bb64 = bsh["echo ".len..std.mem.indexOf(u8, bsh, " |").?];
    const bbuf = try t.allocator.alloc(u8, try dec.calcSizeForSlice(bb64));
    defer t.allocator.free(bbuf);
    try dec.decode(bbuf, bb64);
    try t.expect(std.mem.indexOf(u8, bbuf, "NEEDRESTART_SUSPEND=1 bash /tmp/.sk_aabbccddeeff.c") != null);
    try t.expect(std.mem.indexOf(u8, bsh, "&& sh /tmp/.sk_aabbccddeeff;") != null);
}

test "findSentinel extracts output and status" {
    const t = std.testing;
    const nonce = "aabbccddeeff";
    const text = "$ printf ... SKB''aabbccddeeff; ...\nSKBaabbccddeeff\nhello\nworld\nSKEaabbccddeeff.3\n$ ";
    const r = findSentinel(text, nonce);
    try t.expect(r == .done);
    try t.expectEqual(@as(i32, 3), r.done.status);
    try t.expectEqualStrings("hello\nworld\n", text[r.done.start..r.done.end]);
    try t.expect(!r.done.truncated);
    // No end marker yet: pending.
    try t.expect(findSentinel("SKBaabbccddeeff\npartial", nonce) == .pending);
    // Begin marker scrolled away: truncated tail.
    const tail = findSentinel("late output\nSKEaabbccddeeff.0\n", nonce);
    try t.expect(tail == .done and tail.done.truncated);
    // The echoed quote-split typed text never matches.
    try t.expect(findSentinel("$ printf '\\n%s\\n' SKB''aabbccddeeff; if ...", nonce) == .pending);
}

pub const TokenResult = union(enum) {
    /// No shell integration was injected for this shell.
    unsupported,
    /// Integration is injected but no prompt mark has arrived within
    /// the wait — slow shell startup, or a shell whose rc files broke
    /// the injection. Retryable, unlike `unsupported`.
    not_ready,
    /// A foreground command (started outside command mode) is still
    /// between OSC 133 C and D; its D would be misattributed to a new
    /// command-mode send.
    busy,
    token: CommandToken,
};

var name_counter: u32 = 0;

pub const Term = struct {
    allocator: std.mem.Allocator,
    conn: muxclient.Conn,
    name: []u8,
    origin_id: wire.SessionOriginId = undefined,
    origin_id_valid: bool = false,
    pool: *Pool,
    screen: ?*Screen = null,
    /// Highest snapshot/events seq seen — the quiescence signal.
    seq: u64 = 0,
    events_desynced: bool = false,
    exited: bool = false,
    exit_status: i32 = 0,
    exit_status_known: bool = false,
    app_cursor: bool = false,
    integration: bool = false,
    /// Basename of the shell driving this term. Local terms know it
    /// at spawn; ssh terms get it from the bootstrap's announce line
    /// (scanShellAnnounce). Null = not (yet) known.
    shell_name: ?[]u8 = null,
    /// An ssh bootstrap was injected: an announce line is expected.
    remote_shell_pending: bool = false,
    /// The announce line has been parsed; shell_name is authoritative.
    shell_announced: bool = false,
    /// Session lives on THIS host's own sketerm-mux daemon (spawned
    /// over connectSsh). Non-null enables the transparent one-shot
    /// reattach on transport loss — the remote daemon keeps the
    /// session alive across connection drops.
    remote_host: ?[]u8 = null,
    /// One reattach already failed: transport loss is final. Never
    /// retried, so a dead host costs ONE bounded connect attempt, not
    /// one per drain.
    reattach_spent: bool = false,
    /// One full-length first-prompt wait already expired with no mark:
    /// later commandToken calls fail fast instead of re-burning it.
    /// Never blocks success — a mark that shows up later still wins.
    prompt_wait_exhausted: bool = false,
    pending_command: ?CommandToken = null,
    pending_exec: ?ExecPending = null,

    /// Spawn a shell session on the daemon at `local_sock` (null = the
    /// shared per-user daemon) and attach. `argv` null = the login
    /// shell; non-null runs that argv.
    pub fn spawn(
        allocator: std.mem.Allocator,
        argv: ?[]const []const u8,
        cols: u16,
        rows: u16,
        local_sock: ?[]const u8,
    ) Error!*Term {
        var conn = muxclient.Conn.connectLocalAutostartAt(allocator, local_sock) catch return Error.SpawnFailed;
        errdefer conn.deinit();
        // Non-blocking + deadline recv everywhere: a wedged daemon
        // costs a bounded error, never a hung MCP tool call.
        conn.setNonBlocking();
        conn.sendJson(.hello, .{ .proto = wire.PROTO_VERSION }) catch return Error.SpawnFailed;
        (conn.recvExpectFor(&.{.welcome}, 15_000) catch return Error.SpawnFailed).deinit(allocator);
        if (!conn.kill_origin_fence) return Error.SpawnFailed;

        name_counter += 1;
        const name = std.fmt.allocPrint(allocator, "mcpterm-{d}-{d}", .{ c.getpid(), name_counter }) catch
            return Error.OutOfMemory;
        errdefer allocator.free(name);

        // Auto shell-integration, like a GUI pane would get: the OSC
        // 133 zones it injects are what powers term_run output_only.
        // The daemon is local (term tools are isolated-mode only), so
        // client-resolved script paths are valid on its host. With no
        // explicit argv, resolve the same account shell as the local daemon.
        const shellintegration = @import("../util/shellintegration.zig");
        const shell: []const u8 = if (argv) |av| av[0] else @import("../mux/shell.zig").accountLoginShell();
        const si = shellintegration.resolve(allocator, shell);
        defer if (si) |r| r.deinit(allocator);
        const SiWire = struct { kind: []const u8, script: []const u8, shim_dir: []const u8 };
        const si_wire: ?SiWire = if (si) |r| .{ .kind = r.kind, .script = r.script, .shim_dir = r.shim } else null;

        if (argv) |av| {
            conn.sendJson(.spawn, .{ .name = name, .argv = av, .rows = rows, .cols = cols, .shell_integration = si_wire }) catch return Error.SpawnFailed;
        } else {
            conn.sendJson(.spawn, .{ .name = name, .argv = &.{shell}, .rows = rows, .cols = cols, .login_shell = true, .shell_integration = si_wire }) catch return Error.SpawnFailed;
        }
        const ok = conn.recvExpectFor(&.{.ok}, 15_000) catch return Error.SpawnFailed;
        defer ok.deinit(allocator);
        return finishSpawn(
            allocator,
            &conn,
            name,
            shell,
            si != null,
            null,
            .{ .target = .{ .local = local_sock } },
            ok.payload,
            15_000,
        );
    }

    /// Spawn a session on `host`'s OWN sketerm-mux daemon (found via
    /// `ssh host sketerm-mux --proxy`; requires key auth + the binary
    /// in the remote PATH — the caller falls back to plain ssh when
    /// this errors). The session survives connection drops on the
    /// remote daemon; ttl_secs bounds orphans if this client dies
    /// without a kill.
    pub fn spawnRemoteMux(
        allocator: std.mem.Allocator,
        host: []const u8,
        argv: []const []const u8,
        cols: u16,
        rows: u16,
    ) Error!*Term {
        var conn = muxclient.Conn.connectSsh(allocator, host) catch return Error.SpawnFailed;
        errdefer conn.deinit();
        // connectSsh already proved hello → welcome; just bound reads.
        conn.setNonBlocking();
        if (!conn.kill_origin_fence) return Error.SpawnFailed;

        name_counter += 1;
        const name = std.fmt.allocPrint(allocator, "mcpterm-{d}-{d}", .{ c.getpid(), name_counter }) catch
            return Error.OutOfMemory;
        errdefer allocator.free(name);

        conn.sendJson(.spawn, .{ .name = name, .argv = argv, .rows = rows, .cols = cols, .ttl_secs = 3600 }) catch return Error.SpawnFailed;
        const ok = conn.recvExpectFor(&.{.ok}, 15_000) catch return Error.SpawnFailed;
        defer ok.deinit(allocator);
        return finishSpawn(
            allocator,
            &conn,
            name,
            argv[0],
            false,
            host,
            .{ .target = .{ .remote = host } },
            ok.payload,
            15_000,
        );
    }

    fn finishSpawn(
        allocator: std.mem.Allocator,
        conn: *muxclient.Conn,
        name: []u8,
        shell: []const u8,
        integration: bool,
        remote_host: ?[]const u8,
        endpoint: launch_cleanup.Endpoint,
        spawn_payload: []const u8,
        timeout_ms: i64,
    ) Error!*Term {
        const meta = launch_cleanup.parseSpawnMeta(spawn_payload) catch return Error.SpawnFailed;
        var cleanup = launch_cleanup.Guard.init(conn, name, meta.origin_id, endpoint, timeout_ms);
        errdefer cleanup.rollback();

        conn.sendAttach(name, .{
            .origin_id = &meta.origin_id,
            .kind = "mcp",
        }) catch return Error.SpawnFailed;
        const snap = conn.recvExpectFor(&.{.snapshot}, timeout_ms) catch |err|
            return if (err == error.OutOfMemory) Error.OutOfMemory else Error.SpawnFailed;
        defer snap.deinit(allocator);

        // Best-effort, like appdrive's: the mirror backs term_read, not the
        // session. A snapshot skew against a pre-upgrade daemon must leave
        // the term attached and usable, not kill a shell that just spawned.
        const restored: ?snapshot.OwnedRestore = snapshot.restoreOwned(allocator, snap.payload) catch null;
        errdefer if (restored) |r| r.deinit(allocator);
        const pool = if (restored) |r| r.pool else blk: {
            const p = allocator.create(Pool) catch return Error.OutOfMemory;
            p.* = Pool.init(allocator) catch {
                allocator.destroy(p);
                return Error.OutOfMemory;
            };
            break :blk p;
        };
        errdefer if (restored == null) {
            pool.deinit();
            allocator.destroy(pool);
        };
        const shell_name = allocator.dupe(u8, std.fs.path.basename(shell)) catch return Error.OutOfMemory;
        errdefer allocator.free(shell_name);
        const host_owned = if (remote_host) |host|
            allocator.dupe(u8, host) catch return Error.OutOfMemory
        else
            null;
        errdefer if (host_owned) |host| allocator.free(host);
        const self = allocator.create(Term) catch return Error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .conn = conn.*,
            .name = name,
            .origin_id = meta.origin_id,
            .origin_id_valid = true,
            .pool = pool,
            .screen = if (restored) |r| r.screen else null,
            .seq = if (restored) |r| r.seq else 0,
            .integration = integration,
            .shell_name = shell_name,
            .remote_host = host_owned,
        };
        if (self.screen) |mirror| self.app_cursor = mirror.app_cursor_keys;
        cleanup.disarm();
        return self;
    }

    pub fn deinit(self: *Term) void {
        const a = self.allocator;
        if (!self.exited) self.conn.sendKill(.{
            .name = self.name,
            .origin_id = if (self.origin_id_valid) &self.origin_id else "",
        }) catch {};
        if (self.shell_name) |s| a.free(s);
        if (self.remote_host) |h| a.free(h);
        self.conn.deinit();
        if (self.screen) |s| s.deinit();
        self.pool.deinit();
        a.destroy(self.pool);
        a.free(self.name);
        a.destroy(self);
    }

    /// Swap the mirror for a freshly restored one. Failure-atomic: the
    /// previous screen keeps serving reads if the new body will not decode.
    fn applySnapshot(self: *Term, payload: []const u8) !void {
        const a = self.allocator;
        const restored = try snapshot.restoreOwned(a, payload);
        if (self.screen) |s| s.deinit();
        self.pool.deinit();
        a.destroy(self.pool);
        self.seq = restored.seq;
        self.pool = restored.pool;
        self.screen = restored.screen;
        self.app_cursor = restored.screen.app_cursor_keys;
        self.events_desynced = false;
    }

    fn applyScreenEvent(screen: *Screen, ev: Event) void {
        screen.apply(ev);
    }

    fn applyEvents(self: *Term, payload: []const u8) void {
        if (self.events_desynced) return;
        const screen = self.screen orelse return;
        self.seq = wire.applyEventFrame(
            payload,
            self.seq,
            self.allocator,
            screen,
            applyScreenEvent,
        ) catch {
            self.events_desynced = true;
            return;
        };
        self.app_cursor = screen.app_cursor_keys;
    }

    fn handleFrame(self: *Term, ftype: wire.FrameType, payload: []const u8) void {
        switch (ftype) {
            .snapshot => self.applySnapshot(payload) catch {},
            .events => self.applyEvents(payload),
            .exit => {
                self.exited = true;
                if (payload.len >= 4) {
                    self.exit_status = std.mem.readInt(i32, payload[0..4], .little);
                    self.exit_status_known = true;
                }
            },
            .gone => self.exited = true,
            else => {},
        }
    }

    fn pollIn(fd: c_int, ms: i32) bool {
        var pfd = c.struct_pollfd{ .fd = fd, .events = c.POLLIN, .revents = 0 };
        return c.poll(&pfd, 1, ms) > 0 and (pfd.revents & (c.POLLIN | c.POLLHUP)) != 0;
    }

    /// Process at most one COMPLETE queued frame, waiting up to
    /// `wait_ms`. Never blocks past that: a readable fd does not mean
    /// a whole frame arrived, so this peels from the buffer instead
    /// of calling recvFrame (whose read() would park on a frame tail
    /// a wedged daemon never sends).
    pub fn pumpOnce(self: *Term, wait_ms: i32) bool {
        if (self.exited) return false;
        if (self.takeOne()) return true;
        if (!pollIn(self.conn.fd, wait_ms)) return false;
        if (!self.conn.fillAvailable()) {
            self.transportLost();
            return false;
        }
        return self.takeOne();
    }

    fn takeOne(self: *Term) bool {
        const f = (self.conn.takeFrame() catch {
            self.transportLost();
            return false;
        }) orelse return false;
        defer f.deinit(self.allocator);
        self.handleFrame(f.ftype, f.payload);
        return true;
    }

    /// The connection died WITHOUT an .exit frame. A remote-mux
    /// session survives on its daemon, so try one bounded reattach
    /// (fresh ssh + attach + snapshot resync) — transparent to the
    /// caller, which just sees the mirror continue. A failed attempt
    /// is final for THIS drop (exited); success re-arms the shot for
    /// the next drop. Local terms share their daemon's fate: exited.
    fn transportLost(self: *Term) void {
        const host = self.remote_host orelse {
            self.exited = true;
            return;
        };
        if (self.reattach_spent) {
            self.exited = true;
            return;
        }
        self.reattach_spent = true;
        var conn = muxclient.Conn.connectSshOnce(self.allocator, host) catch {
            self.exited = true;
            return;
        };
        conn.setNonBlocking();
        conn.sendAttach(self.name, .{
            .origin_id = if (self.origin_id_valid) &self.origin_id else "",
            .kind = "mcp",
        }) catch {
            conn.deinit();
            self.exited = true;
            return;
        };
        const snap = conn.recvExpectFor(&.{.snapshot}, 15_000) catch {
            conn.deinit();
            self.exited = true;
            return;
        };
        defer snap.deinit(self.allocator);
        self.conn.deinit();
        self.conn = conn;
        self.applySnapshot(snap.payload) catch {};
        self.reattach_spent = false;
    }

    /// Time-boxed like appdrive.drain: a flooding shell (`cat` of a
    /// huge file) must not wedge the single-threaded MCP loop.
    pub fn drain(self: *Term) void {
        const deadline = nowMs() + 100;
        while (self.pumpOnce(0)) {
            if (nowMs() >= deadline) break;
        }
    }

    /// Raw bytes to the shell's PTY.
    pub fn sendText(self: *Term, text: []const u8) Error!void {
        if (self.exited) return Error.NotConnected;
        self.conn.sendFrame(.input, text) catch return Error.NotConnected;
    }

    /// Named-key chords ("ctrl+c", "enter", "up", ...), space-separated.
    pub fn sendKeys(self: *Term, chords: []const u8) Error!void {
        self.drain(); // refresh app_cursor from any pending events
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.allocator);
        keys.encode(&out, self.allocator, chords, self.app_cursor) catch return Error.BadKey;
        self.conn.sendFrame(.input, out.items) catch return Error.NotConnected;
    }

    /// Ask the daemon to record this session as an asciicast v2 file
    /// at `path` (on the daemon's host). Fire-and-forget: the ok/err
    /// reply rides the frame stream and is ignored by handleFrame, so
    /// a bad path just means no file appears. The daemon finalizes
    /// the cast when the session ends and fflushes per event, so the
    /// file is replayable at any point.
    pub fn startRecording(self: *Term, path: []const u8) void {
        if (self.exited) return;
        self.conn.sendJson(.rec_start, .{ .path = path }) catch {};
    }

    pub fn resize(self: *Term, cols: u16, rows: u16) Error!void {
        if (self.exited) return Error.NotConnected;
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], rows, .little);
        std.mem.writeInt(u16, buf[2..4], cols, .little);
        self.conn.sendFrame(.resize, &buf) catch return Error.NotConnected;
    }

    /// Output + exit code of the last COMPLETED command (OSC 133
    /// zone, mirrored from the daemon's event stream). Null when no
    /// zone exists yet (shell integration off, or nothing ran).
    /// Caller owns `.text`.
    pub fn lastCommand(self: *Term) Error!?struct { text: []u8, exit: i32 } {
        self.drain();
        const screen = self.screen orelse return Error.NotConnected;
        const text = (screen.extractLastCommandOutput(self.allocator) catch return Error.OutOfMemory) orelse
            return null;
        return .{ .text = text, .exit = screen.last_cmd_exit };
    }

    fn commandTokenFor(screen: *const Screen) CommandToken {
        return .{ .completion_seq = screen.cmd_completion_seq };
    }

    /// Capture the completed-zone baseline for a command-mode send.
    /// Integration was injected at spawn but the first prompt may not
    /// have rendered yet on a freshly opened terminal, so this waits
    /// (bounded by `wait_ms`) for the first OSC 133 prompt mark
    /// instead of misreporting a race as unsupported.
    pub fn commandToken(self: *Term, wait_ms: i64) Error!TokenResult {
        self.drain();
        if (self.exited) return Error.NotConnected;
        if (self.screen == null) return Error.NotConnected;
        // A late remote announce may have flipped integration off
        // (dash/fish remote): pick it up before deciding.
        _ = self.scanShellAnnounce();
        if (!self.integration) return .unsupported;
        const deadline = nowMs() + wait_ms;
        while (true) {
            // Re-fetch each pass: a resync snapshot swaps self.screen.
            const screen = self.screen orelse return Error.NotConnected;
            if (screen.prompt_marks_len > 0) break;
            if (self.exited) return Error.NotConnected;
            if (self.prompt_wait_exhausted or nowMs() >= deadline) {
                self.prompt_wait_exhausted = true;
                return .not_ready;
            }
            _ = self.pumpOnce(50);
        }
        // A raw send's Enter races its OSC 133 C mark: settle briefly
        // so an in-flight command surfaces before the busy judgment,
        // or its D would complete the new command-mode wait.
        _ = self.waitIdle(100, 500);
        if (self.exited) return Error.NotConnected;
        const screen = self.screen orelse return Error.NotConnected;
        if (screen.pending_output_start_id != 0 or screen.pending_output_awaits_nl)
            return .busy;
        return .{ .token = commandTokenFor(screen) };
    }

    /// SSH terms: the local argv[0] ("ssh") is NOT the session's
    /// shell — clear it. With `expect_announce` the injected
    /// bootstrap's announce line (scanShellAnnounce) fills it in once
    /// the remote side reports; without, it stays unknown.
    pub fn setRemoteShellPending(self: *Term, expect_announce: bool) void {
        if (self.shell_name) |s| self.allocator.free(s);
        self.shell_name = null;
        self.remote_shell_pending = expect_announce;
    }

    /// Parse the ssh bootstrap's "[sketerm] remote shell: <name>
    /// (integration injected|no integration)" line out of the mirror
    /// and cache it. A "no integration" verdict flips `integration`
    /// off so command mode refuses cleanly instead of burning the
    /// first-prompt wait. Returns true once known.
    pub fn scanShellAnnounce(self: *Term) bool {
        if (self.shell_announced) return true;
        if (!self.remote_shell_pending) return false;
        self.drain();
        const screen = self.screen orelse return false;
        const text = screen.extractScrollback(self.allocator) catch return false;
        defer self.allocator.free(text);
        const prefix = "[sketerm] remote shell: ";
        const idx = std.mem.indexOf(u8, text, prefix) orelse return false;
        const rest = text[idx + prefix.len ..];
        const eol = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const line = std.mem.trimEnd(u8, rest[0..eol], " \r");
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return false;
        const name = line[0..sp];
        if (name.len == 0 or name.len > 64) return false;
        const integrated = std.mem.indexOf(u8, line, "(integration injected)") != null;
        if (self.shell_name) |old| self.allocator.free(old);
        self.shell_name = self.allocator.dupe(u8, name) catch null;
        self.shell_announced = true;
        if (!integrated) self.integration = false;
        return true;
    }

    /// True when the mirrored screen shows an OSC 133 command zone
    /// still open — a foreground command (or a mark-less program like
    /// a REPL) is running. Only meaningful when integration is active.
    pub fn foregroundRunning(self: *Term) bool {
        self.drain();
        const screen = self.screen orelse return false;
        return screen.pending_output_start_id != 0 or screen.pending_output_awaits_nl;
    }

    pub fn trackCommand(self: *Term, token: CommandToken) void {
        self.pending_command = token;
    }

    pub fn hasPendingCommand(self: *const Term) bool {
        return self.pending_command != null;
    }

    /// Wait for a new OSC 133 command zone or a tracked shell-process exit.
    pub fn waitCommand(self: *Term, token: CommandToken, timeout_ms: i64) CommandCompletion {
        const deadline = nowMs() + timeout_ms;
        while (true) {
            _ = self.pumpOnce(50);
            if (self.screen) |screen| {
                const current = commandTokenFor(screen);
                if (!std.meta.eql(token, current)) {
                    self.pending_command = null;
                    return .{
                        .state = .completed,
                        .exit_status = screen.last_cmd_exit,
                        .source = .shell_integration,
                    };
                }
            }
            if (self.exited) {
                if (self.exit_status_known) {
                    self.pending_command = null;
                    return .{
                        .state = .completed,
                        .exit_status = self.exit_status,
                        .source = .process_tracking,
                    };
                }
                self.pending_command = null;
                return .{ .state = .unknown };
            }
            if (nowMs() >= deadline) {
                // Nothing completed: no source to attribute.
                return .{
                    .state = .running,
                    .timed_out = true,
                    .source = .none,
                };
            }
        }
    }

    pub fn waitPendingCommand(self: *Term, timeout_ms: i64) ?CommandCompletion {
        const token = self.pending_command orelse return null;
        return self.waitCommand(token, timeout_ms);
    }

    /// Block until the terminal's child process exits (or timeout).
    /// Returns true when it exited; exit_status/exit_status_known then
    /// carry the result.
    pub fn waitExit(self: *Term, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        while (!self.exited) {
            if (nowMs() >= deadline) return false;
            _ = self.pumpOnce(50);
        }
        return true;
    }

    pub fn hasPendingExec(self: *const Term) bool {
        return self.pending_exec != null;
    }

    /// Sentinel-based structured exec inside the LIVE interactive
    /// shell (works over SSH, where OSC 133 integration cannot reach).
    /// On timeout the sentinel stays pending; continue with
    /// waitExecResult. Caller frees `.output`.
    pub fn execCommand(self: *Term, command: []const u8, subshell: bool, noninteractive: bool, shell: ?[]const u8, timeout_ms: i64) Error!ExecOutcome {
        self.drain();
        if (self.exited) return Error.NotConnected;
        if (self.pending_exec != null) return Error.BadKey; // caller checks hasPendingExec first
        var pend: ExecPending = undefined;
        var raw: [6]u8 = undefined;
        if (c.getentropy(&raw, raw.len) != 0) return Error.SpawnFailed;
        const hex = "0123456789abcdef";
        for (raw, 0..) |b, i| {
            pend.nonce[i * 2] = hex[b >> 4];
            pend.nonce[i * 2 + 1] = hex[b & 0xf];
        }
        const line = buildExecLine(self.allocator, &pend.nonce, command, subshell, noninteractive, shell) catch return Error.OutOfMemory;
        defer self.allocator.free(line);
        const with_cr = std.fmt.allocPrint(self.allocator, "{s}\r", .{line}) catch return Error.OutOfMemory;
        defer self.allocator.free(with_cr);
        try self.sendText(with_cr);
        self.pending_exec = pend;
        return self.waitExecResult(timeout_ms) orelse Error.NotConnected;
    }

    /// Continue waiting for a pending exec sentinel. Null when none is
    /// pending. Caller frees `.output`.
    ///
    /// Returns EARLY (before timeout_ms) when the terminal has been
    /// output-idle behind something that looks like an interactive
    /// prompt or an alt-screen UI: burning the whole timeout there
    /// would just hide the question — the caller should show the
    /// screen and answer via sendText/sendKeys; the tracker stays
    /// attached either way.
    pub fn waitExecResult(self: *Term, timeout_ms: i64) ?ExecOutcome {
        const pend = self.pending_exec orelse return null;
        const deadline = nowMs() + timeout_ms;
        var last_seq = self.seq;
        var last_change = nowMs();
        while (true) {
            _ = self.pumpOnce(50);
            if (self.seq != last_seq) {
                last_seq = self.seq;
                last_change = nowMs();
            }
            // Scan at a coarse cadence: extracting the whole
            // scrollback per pump would hurt under output floods.
            const text = blk: {
                const screen = self.screen orelse break :blk null;
                break :blk screen.extractScrollback(self.allocator) catch null;
            };
            var partial_from: ?usize = null;
            if (text) |t| {
                switch (findSentinel(t, &pend.nonce)) {
                    .done => |d| {
                        defer self.allocator.free(t);
                        self.pending_exec = null;
                        const out = self.allocator.dupe(u8, t[d.start..d.end]) catch &[_]u8{};
                        return .{
                            .completed = true,
                            .exit_status = d.status,
                            .output = @constCast(out),
                            .truncated = d.truncated,
                        };
                    },
                    .pending => |p| partial_from = p.begin_after,
                }
            }
            defer if (text) |t| self.allocator.free(t);
            if (self.exited) {
                self.pending_exec = null;
                return .{ .completed = false, .shell_died = true, .exit_status = if (self.exit_status_known) self.exit_status else null };
            }
            const idle_ms = nowMs() - last_change;
            const alt = if (self.screen) |s| s.use_alt else false;
            var interactive = alt;
            if (!interactive) {
                if (text) |t| {
                    if (partial_from) |from| {
                        var it = std.mem.splitBackwardsScalar(u8, t[from..], '\n');
                        while (it.next()) |line| {
                            const trimmed = std.mem.trim(u8, line, " \t\r");
                            if (trimmed.len == 0) continue;
                            interactive = looksInteractive(trimmed);
                            break;
                        }
                    }
                }
            }
            const give_up = nowMs() >= deadline or (interactive and idle_ms >= 2_500);
            if (give_up) {
                const partial: []u8 = blk: {
                    const t = text orelse break :blk @constCast(&[_]u8{});
                    const from = partial_from orelse break :blk @constCast(&[_]u8{});
                    break :blk @constCast(self.allocator.dupe(u8, t[from..]) catch &[_]u8{});
                };
                return .{
                    .completed = false,
                    .timed_out = nowMs() >= deadline,
                    .pending = true,
                    .tracker = pend.nonce,
                    .output = partial,
                    .alt_screen = alt,
                    .idle_ms = idle_ms,
                    .interactive_hint = interactive,
                };
            }
            // Pace the scrollback scans.
            var waited: i64 = 0;
            while (waited < 100 and nowMs() < deadline) {
                if (self.pumpOnce(50)) {
                    if (self.seq != last_seq) {
                        last_seq = self.seq;
                        last_change = nowMs();
                    }
                } else waited += 50;
                if (self.exited) break;
            }
        }
    }

    /// Rendered screen text (drains pending events first).
    pub fn readScreen(self: *Term, scrollback: bool) Error![]u8 {
        self.drain();
        const screen = self.screen orelse return Error.NotConnected;
        return (if (scrollback)
            screen.extractScrollback(self.allocator)
        else
            screen.extractScreen(self.allocator)) catch Error.OutOfMemory;
    }

    /// Block until output is quiet; this does not imply the foreground command exited.
    pub fn waitIdle(self: *Term, quiet_ms: i64, timeout_ms: i64) bool {
        const deadline = nowMs() + timeout_ms;
        var last_seq = self.seq;
        var last_change = nowMs();
        while (true) {
            _ = self.pumpOnce(50);
            const now = nowMs();
            if (self.seq != last_seq) {
                last_seq = self.seq;
                last_change = now;
            }
            if (self.exited) return true;
            if (now - last_change >= quiet_ms) return true;
            if (now >= deadline) return false;
        }
    }
};

const SpawnFailure = enum { attach_send, snapshot_timeout, cleanup_connect };

fn testSpawnFailure(failure: SpawnFailure) !void {
    const t = std.testing;
    const fake = @import("launch_cleanup_test.zig");
    var daemon = try fake.Harness.init(t.allocator);
    defer daemon.deinit();
    const name = try t.allocator.dupe(u8, "fake-term");
    defer t.allocator.free(name);
    var conn = daemon.takePrimary(t.allocator);
    defer conn.deinit();
    const endpoint = daemon.remoteEndpoint();

    switch (failure) {
        .attach_send => {
            _ = c.close(conn.fd);
            conn.fd = -1;
            try daemon.queueFreshAck();
        },
        .snapshot_timeout => try daemon.queueFreshAck(),
        .cleanup_connect => {
            daemon.closePrimaryPeer();
            daemon.reconnect_fails = true;
        },
    }

    try t.expectError(Error.SpawnFailed, Term.finishSpawn(
        t.allocator,
        &conn,
        name,
        "/bin/sh",
        false,
        "fake-host",
        endpoint,
        fake.SPAWN_REPLY,
        5,
    ));
    switch (failure) {
        .attach_send => try daemon.expectFreshKill(name),
        .snapshot_timeout => {
            try daemon.expectAttach(name, false);
            try daemon.expectPrimaryKill(name);
            try daemon.expectFreshKill(name);
        },
        .cleanup_connect => try t.expectEqual(@as(usize, 1), daemon.reconnect_calls),
    }
    if (failure != .cleanup_connect) try daemon.expectSessionGone();
}

test "Term spawn rolls back when attach send fails" {
    try testSpawnFailure(.attach_send);
}

test "Term spawn survives a snapshot it cannot decode" {
    const t = std.testing;
    const fake = @import("launch_cleanup_test.zig");
    var daemon = try fake.Harness.init(t.allocator);
    defer daemon.deinit();
    const name = try t.allocator.dupe(u8, "fake-term");
    var conn = daemon.takePrimary(t.allocator);
    const endpoint = daemon.remoteEndpoint();
    try daemon.queueSnapshot("not-a-snapshot");

    // The mirror backs term_read; it is not the session. A snapshot skew
    // against a pre-upgrade daemon used to kill a shell that had spawned
    // and was running fine.
    const term = try Term.finishSpawn(
        t.allocator,
        &conn,
        name,
        "/bin/sh",
        false,
        "fake-host",
        endpoint,
        fake.SPAWN_REPLY,
        5,
    );
    try t.expect(term.screen == null);
    try t.expectEqual(@as(u64, 0), term.seq);
    try daemon.expectAttach(name, false);
    term.exited = true; // deinit must not send a kill through the fake
    term.deinit();
}

test "Term spawn rolls back a timed-out snapshot over a fresh connection" {
    try testSpawnFailure(.snapshot_timeout);
}

test "Term spawn preserves its error when cleanup cannot connect" {
    try testSpawnFailure(.cleanup_connect);
}

fn testSpawnAllocationFailures(remote: bool) !void {
    const t = std.testing;
    const fake = @import("launch_cleanup_test.zig");
    const snapshot_payload = try fake.snapshotPayload(t.allocator, false);
    defer t.allocator.free(snapshot_payload);

    var baseline = std.testing.FailingAllocator.init(t.allocator, .{});
    const baseline_allocator = baseline.allocator();
    const baseline_name = try baseline_allocator.dupe(u8, "fake-term");
    const first_post_spawn = baseline.alloc_index;
    var baseline_daemon = try fake.Harness.init(t.allocator);
    defer baseline_daemon.deinit();
    try baseline_daemon.queueSnapshot(snapshot_payload);
    var baseline_conn = baseline_daemon.takePrimary(baseline_allocator);
    const baseline_endpoint = if (remote) baseline_daemon.remoteEndpoint() else baseline_daemon.localEndpoint();
    const term = try Term.finishSpawn(
        baseline_allocator,
        &baseline_conn,
        baseline_name,
        "/bin/sh",
        !remote,
        if (remote) "fake-host" else null,
        baseline_endpoint,
        fake.SPAWN_REPLY,
        20,
    );
    const allocation_end = baseline.alloc_index;
    try t.expect(allocation_end > first_post_spawn);
    try baseline_daemon.expectAttach(baseline_name, false);
    try baseline_daemon.expectPrimaryQuiet();
    term.deinit();
    try baseline_daemon.expectPrimaryKill("fake-term");
    try baseline_daemon.expectSessionGone();
    try t.expectEqual(@as(usize, 0), baseline_daemon.reconnect_calls);

    var fail_index = first_post_spawn;
    while (fail_index < allocation_end) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(t.allocator, .{ .fail_index = fail_index });
        const allocator = failing.allocator();
        const name = try allocator.dupe(u8, "fake-term");
        defer allocator.free(name);
        var daemon = try fake.Harness.init(t.allocator);
        defer daemon.deinit();
        try daemon.queueSnapshot(snapshot_payload);
        try daemon.queueFreshAck();
        var conn = daemon.takePrimary(allocator);
        defer conn.deinit();
        const endpoint = if (remote) daemon.remoteEndpoint() else daemon.localEndpoint();
        _ = Term.finishSpawn(
            allocator,
            &conn,
            name,
            "/bin/sh",
            !remote,
            if (remote) "fake-host" else null,
            endpoint,
            fake.SPAWN_REPLY,
            20,
        ) catch {};
        try t.expect(failing.has_induced_failure);
        try daemon.expectFreshKill(name);
        try daemon.expectSessionGone();
        try t.expectEqual(@as(usize, 1), daemon.reconnect_calls);
    }
}

test "Term local spawn rolls back every post-spawn allocation failure" {
    try testSpawnAllocationFailures(false);
}

test "Term remote mux spawn rolls back every post-spawn allocation failure" {
    try testSpawnAllocationFailures(true);
}
