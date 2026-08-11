# sketerm-mux — durable panes & remote domains (design)

Status: **historical design draft — SHIPPED and since evolved.** This is
the document that argued for the mux, kept for its rationale. It is not
a description of the current system, and where the two disagree the code
wins. For what actually exists, read `docs/architecture.md`, `REMOTE.md`
and `src/mux/CLAUDE.md`. The largest divergence: the design speaks of an
optional daemon alongside an in-process terminal path, and the shipped
architecture has no in-process path at all — the GUI is ALWAYS a mux
client, and the per-pane worker thread and its event ring are gone.

## Why

tmux is an inner terminal emulator: it parses application output,
keeps its own screen model, and re-encodes it as escape sequences
downgraded to what it believes the outer terminal supports. Every
"special" feature (OSC 52, kitty graphics, hyperlinks, kitty
keyboard protocol, synchronized output) needs explicit tmux
cooperation and user configuration, and you live inside tmux's
scrollback, status line, and prefix key.

sketerm's pipeline is already *PTY bytes → parser → tagged-union
`Event` → SPSC ring → `Screen`*, and nothing in parser/Screen
touches GTK (the `zig build replay` tool runs the whole terminal
core headless). That makes a fundamentally better mux possible: move
the PTY + parser + authoritative Screen into a small daemon and
stream **parsed events** to the GUI instead of re-encoded escape
sequences. Same parser, same Screen type, same rendering on both
ends. Kitty graphics, OSC 52, SGR 58, hyperlinks — everything works
through it *by construction*, and every future feature is
mux-compatible for free. tmux can never have that property; its wire
format is the escape-sequence soup itself.

## The three questions

**Do I have to install sketerm on the server?** Yes, but not the GUI.
`sketerm-mux` is a separate lean binary: pty.zig + parser + Screen +
the wire protocol. No GTK, no freetype/harfbuzz/epoxy — just libc.
It builds from the same repo (one more `b.addExecutable` with a tiny
dependency set) and Zig cross-compiles trivially, so
`zig build mux -Dtarget=aarch64-linux` for the odd ARM box is
realistic. Deployment is "scp one binary".

**Can it be mosh-like (UDP, roaming)?** Eventually, yes — and the
architecture should be designed so that's a transport swap, not a
rewrite. Key insight: mosh's State Synchronization Protocol doesn't
stream a byte log; it synchronizes *terminal state* with diffs over
datagrams, idempotently, so lost packets just mean the next diff is
bigger. We have an authoritative `Screen` on the daemon side — which
is exactly the state object SSP wants. So the protocol below defines
two sync modes over one session abstraction:

- **Event stream** (reliable transport: Unix socket, SSH pipe, TCP):
  forward each parsed `Event` in order. Lossless, minimal latency,
  trivial.
- **State sync** (lossy transport: UDP later): daemon periodically
  serializes Screen + dirty-row diffs keyed by sequence number;
  client acks; retransmit = send a fresher diff, never the old one.
  Roaming falls out of a session key + source-address update on
  authenticated datagrams (mosh's trick).

v1 ships event-stream only. The framing carries a mode byte so state
sync can be added without breaking the wire. What we do NOT get for
free is mosh's *predictive local echo* (its real latency magic) —
that's a client-side speculation layer and is explicitly out of
scope until the basics are boring.

**Can I reattach after restarting the process?** Yes — that's the
core feature, with one honest boundary:

- GUI crash/restart/logout, connection drop, laptop suspend: the
  daemon keeps running, shells keep running, scrollback keeps
  accumulating. Reattach gets a full state snapshot (screen +
  scrollback + modes) and then the live event stream.
- Daemon death (server reboot, `kill -9` of sketerm-mux): children
  get SIGHUP like any orphaned PTY — sessions are gone. Same
  boundary tmux has. (Restarting the *daemon binary* during upgrade
  without killing sessions is a non-goal for v1; tmux doesn't do it
  either.)

## Architecture

```
            local domain (today)            durable / remote domain
┌─────────┐                       ┌─────────┐         ┌──────────────┐
│ GUI     │ PTY ↔ worker ↔ ring   │ GUI     │ socket  │ sketerm-mux  │
│ Pane    │──────────────────────│ Pane    │◄───────►│ session       │
│ +Screen │                       │ +Screen │ events  │ PTY+parser    │
└─────────┘                       └─────────┘ input ► │ +auth Screen  │
                                                      └──────────────┘
```

- **Daemon** (`sketerm-mux`): one process per user per host.
  Listens on `$XDG_RUNTIME_DIR/sketerm/mux.sock` (0700 dir). Owns N
  *sessions*; each session = PTY + worker thread + parser + ring +
  authoritative Screen (the existing Terminal type minus GUI sinks).
  Main loop is a poll loop (no GLib dependency) draining rings into
  Screens and broadcasting events to attached clients.
- **Client** (GUI Pane in "remote" mode): no PTY, no worker. A
  socket reader feeds decoded wire events into the same
  `Screen.apply` path the local drain uses today. Input
  (writeUserInput, resize) goes the other way. Rendering code is
  untouched — Pane just gets its Screen mutated by a different
  source.
- **Remote hosts**: same daemon started on demand via
  `ssh host sketerm-mux --stdio-session <name>` — the SSH pipe IS
  the transport (mode byte says event-stream). No port, no keys, no
  daemon-side networking in v1; sshd is the authn/transport. UDP
  state-sync transport is a later, additive mode.

## Wire protocol (v1)

Framed binary, little-endian, version-negotiated hello.

```
frame := u32 len, u8 type, payload
types (client→daemon):
  HELLO{proto_ver, client_ver}        ATTACH{session, last_seq?}
  SPAWN{argv, cwd, env, rows, cols}   INPUT{bytes}
  RESIZE{rows, cols}                  DETACH    LIST    KILL{session}
types (daemon→client):
  WELCOME{proto_ver, sessions[]}      SNAPSHOT{seq, screen+scrollback+modes}
  EVENTS{first_seq, n, events[]}      EXIT{status}    GONE{reason}
```

- `Event` serialization: the parser's tagged union, encoded
  tag-byte + payload. Variable payloads (OSC/APC strings, image
  chunks) length-prefixed. This is *the* compatibility surface —
  versioned, append-only tags, unknown tags skippable via the length
  prefix.
- `SNAPSHOT` reuses the Screen's existing state: cells + style pool
  + scrollback ring + mode flags + kitty image store metadata.
  Format shares code with layout/replay serialization where
  practical.
- Sequence numbers on EVENTS frames make reattach exact: client
  says `last_seq`, daemon replays from its retained tail (bounded
  ring of recent events) or falls back to a fresh SNAPSHOT when the
  tail has been dropped. This same mechanism later powers the lossy
  state-sync mode.
- Flow control: per-client high-water mark; a slow client gets
  coalesced (dropped EVENTS, fresh SNAPSHOT on catch-up) rather than
  unbounded daemon buffering — the Screen *is* the coalesced state.

## GUI integration

- `Pane` grows a `source: union { local: *Terminal, remote: *MuxClient }`
  — or pragmatically, Terminal grows a remote mode; decide during
  implementation, but the renderer must not care.
- Spawning: profile flag `durable = true`, CLI `sketerm cli new-tab
  --durable`, and a "New Durable Tab" menu entry. Domain config:
  `[domain.<name>]` sections (`host = devbox`) in config.conf.
- Detach is just closing the pane/window; a "Detach" menu action
  also closes without killing. Attach UI: `sketerm cli list-sessions`
  + a picker dialog later.

## Failure modes

- Daemon not running on first durable spawn → client forks it
  (daemonized, setsid), retries the socket with backoff.
- Version skew → HELLO/WELCOME numbers; client refuses politely and
  tells the user to update the older side.
- Two clients, one session → v1: both attach read-write, both render
  (it's a broadcast); no per-client size negotiation — last RESIZE
  wins (tmux semantics, simpler than wezterm's per-client clipping).

## Build order (each step lands working)

1. **Event (de)serialization + tests** — pure, headless, the
   compatibility keystone. Round-trip every Event tag.
2. **Snapshot (de)serialization + tests** — Screen → bytes → Screen,
   asserted equal via the replay-dump format.
3. **Daemon, local only** — spawn/attach/input/resize/detach over
   the Unix socket; tested headless (no GUI needed: a test client
   asserts on snapshots, like spike-shell).
4. **GUI attach** — remote-mode Pane; durable tabs usable locally.
   smoke-e2e grows a durable-pane scenario (kill GUI, relaunch,
   reattach, marker still in get-text).
5. **SSH domain** — `--stdio-session` mode + domain config.
6. *(later)* UDP state-sync transport; *(much later)* predictive echo.

## Non-goals (v1)

Daemon hot-upgrade without session loss; per-client independent
sizes; predictive local echo; Windows; sharing sessions between
users.
