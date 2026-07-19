# MCP Tools

`sketerm mcp` exposes GUI-backed terminal tools in shared mode and
headless `term_*` and `app_*` tools against its isolated mux daemon.

## Terminal waits

Output quiescence and command completion are separate conditions:

- `term_wait_idle`, `wait_idle`, and the default `term_run` mode wait
  only until terminal output stops changing. A foreground process may
  still be running with stdout and stderr redirected.
- `term_run` with `wait_for: "command"` waits for the shell command to
  finish. It uses a new OSC 133 command zone when shell integration is
  active, preserving the shell's exact exit status.
- If the shell process itself exits before OSC 133 `D`, the isolated
  mux session's tracked process status completes the request instead.
  Sketerm never invents an exit status.

Command-mode results contain `state`, `command_sent`, `exit_status`,
`timed_out`, and `completion_source`. Sources are `shell_integration`,
`process_tracking`, or `none`.

When no shell integration was injected (unsupported shell), command
mode returns `state: "unsupported"`, `command_sent: false`, and
`exit_status: null`. The command is not sent because its completion
could not be identified reliably. When integration IS injected but the
shell's first prompt mark has not arrived yet (slow startup, or rc
files that broke the injection), command mode waits bounded (up to 10s
within the call's timeout) and then returns the same unsupported shape
with `timed_out: true` and a reason saying the state is retryable; the
full-length wait is paid only once per terminal.

If a foreground command started outside command mode (an idle-mode
`term_run` or raw `term_send_text`) is still running, command mode
also refuses with `command_sent: false`: the running command's OSC 133
`D` would otherwise be misattributed to the new send. Wait for it
(`term_wait_idle`) before retrying.

A command-mode timeout returns `state: "running"`, `timed_out: true`,
and `completion_source: "none"`, even if output remained idle.
Continue waiting with `term_wait_command`; do not resend the command.
While the tracked command is unresolved, Sketerm rejects BOTH another
command-mode send and an idle-mode `term_run` — running a new command
would let its OSC 133 `D` be misattributed to the tracked one. (If the
tracked command has meanwhile finished, the next `term_run` clears it
automatically and proceeds.) `term_send_text` stays available for
feeding input to the still-running command; avoid using it to start
new commands while a tracked command is pending.

```json
{"command":"timeout 3 sh -c 'sleep 10' >/tmp/silent.log 2>&1","wait_for":"command","timeout_ms":5000,"output_only":true}
```

The default `wait_for: "idle"` remains appropriate for interactive
programs that do not return to a shell prompt.
