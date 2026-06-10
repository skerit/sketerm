# Remote sessions (sketerm-mux)

Durable shells on a remote host, rendered as native sketerm tabs.
The remote side is one lean binary, `sketerm-mux` (libc only, no
GTK), which owns the PTYs so sessions survive disconnects, GUI
restarts, and suspends.

## Install on the server

`sketerm-mux` has no dependencies beyond glibc. Copy it and you are
done:

```
scp /usr/bin/sketerm-mux server:/tmp/
ssh server sudo install -m755 /tmp/sketerm-mux /usr/local/bin/
```

`/usr/local/bin` (or any directory on the default non-interactive
PATH) matters: the GUI reaches the binary by running
`ssh server sketerm-mux --proxy`, which is a **non-login,
non-interactive** shell. `~/.bashrc` often exits early for
non-interactive shells before extending PATH, and `~/.profile` is
not read at all — so `~/bin` installs tend to produce
"sketerm-mux: command not found" even though logging in works.
Check with:

```
ssh server sketerm-mux --help
```

Cross-compiling for a different server architecture works from the
repo: `zig build mux -Dtarget=aarch64-linux`.

## Authentication

Key or agent auth is required. The SSH pipe carries a binary
protocol, so the GUI runs ssh with `BatchMode=yes` — a password
prompt would corrupt the stream, so password-only hosts fail
instead of prompting. Test with `ssh -o BatchMode=yes server true`.

## Usage

```
sketerm ssh server          # durable remote shell as a new tab (SSH transport)
sketerm ssh -u server       # same, over encrypted UDP (mosh-style)
sketerm mux server          # TUI picker: list/attach/create/kill sessions
sketerm mux server list     # scriptable variants: list | attach <name> | new | kill <name>
```

Closing the tab, killing the GUI, or losing the network leaves the
session running; reattach with `sketerm mux server` and the screen
plus scrollback come back exactly.

Named endpoints go in `~/.config/sketerm/config.conf`:

```
[domain.devbox]
host = user@192.168.1.2
transport = udp        # ssh (default) | udp
```

after which `sketerm ssh devbox` works, and the command palette
gains a "New Tab on devbox" entry.

## UDP transport and firewalls

`sketerm ssh -u` (or `transport = udp`) does one SSH round to start
the bootstrap, then switches to ChaCha20-Poly1305-sealed datagrams:
lower latency, loss recovery by retransmission, and roaming — the
session survives IP changes (Wi-Fi → LTE, suspend/resume) without
reconnecting.

By default the remote end binds an **ephemeral** UDP port, which a
strict firewall will drop. Pin a range and open it for UDP, like
mosh's 60000-61000:

```
# ~/.config/sketerm/config.conf (client side)
mux_udp_port_range = 60000:61000
```

The remote bootstrap then binds the first free port in that range
(`sketerm-mux --udp-listen --udp-port 60000:61000`). If the UDP
path is blocked, the client prints a warning after 5 s and gives up
after 15 s — fall back to plain `sketerm ssh server`, which needs
nothing beyond the SSH connection itself.

Typing feel on high-latency links: printable keystrokes are echoed
predictively (underlined until the server confirms), mosh-style.
This activates only when measured RTT exceeds ~60 ms and never at
echo-off prompts (passwords).

## Lifecycle and limits

- Sessions live in the remote daemon. They survive everything on
  the client side, but not the daemon's own death: a server reboot
  or `kill -9` of `sketerm-mux` ends the shells (same boundary as
  tmux).
- The daemon starts on demand and listens on
  `$XDG_RUNTIME_DIR/sketerm/mux.sock` (0700 runtime dir is the
  local trust boundary; nothing listens on the network except the
  per-connection UDP bootstrap, which requires the key announced
  over SSH).
- Kitty-graphics placements are not yet part of the reattach
  snapshot; full-screen apps redraw them on reattach.
