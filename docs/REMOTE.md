# Remote sessions (sketerm-mux)

Durable shells on a remote host, rendered as native sketerm tabs.
The remote side is one lean binary, `sketerm-mux` (libc only, no
GTK), which owns the PTYs so sessions survive disconnects, GUI
restarts, and suspends.

## Install on the server

Deploy the **portable** build — one static binary that runs on any
x86_64 Linux, regardless of CPU generation or libc:

```
scp /usr/lib/sketerm/sketerm-mux-portable server:/tmp/
ssh server sudo install -m755 /tmp/sketerm-mux-portable /usr/local/bin/sketerm-mux
```

(From the repo instead: `zig build mux-portable`, artifact at
`zig-out/bin/sketerm-mux-portable`.)

Do NOT copy `/usr/bin/sketerm-mux`: the default build is optimized
for the CPU it was built on, so a binary from a recent machine dies
with "Illegal instruction" on an older server (e.g. Zen 4 → Zen 2,
which lacks AVX-512). It is also dynamically linked against the
build host's glibc. The portable build (baseline CPU, static musl)
has neither problem.

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
repo: `zig build mux-portable -Dportable-target=aarch64-linux-musl`.

## Authentication

Key or agent auth is required. The SSH pipe carries a binary
protocol, so the GUI runs ssh with `BatchMode=yes` — a password
prompt would corrupt the stream, so password-only hosts fail
instead of prompting. Test with `ssh -o BatchMode=yes server true`.

## Usage

```
sketerm ssh server          # automatic UDP, with SSH fallback
sketerm ssh -u server       # force encrypted UDP (mosh-style)
sketerm mux server          # TUI picker: list/attach/create/kill sessions
sketerm mux ssh:server      # force the SSH-pipe transport
sketerm mux server list     # scriptable variants: list | attach <name> | new | kill <name>
```

Closing the tab, killing the GUI, or losing the network leaves the
session running; reattach with `sketerm mux server` and the screen
plus scrollback come back exactly.

Named endpoints go in `~/.config/sketerm/config.conf`:

```
[domain.devbox]
host = user@192.168.1.2
transport = auto       # auto (default) | ssh | udp
```

after which `sketerm ssh devbox` works, and the command palette
gains a "New Tab on devbox" entry.

## UDP transport and firewalls

Bare hosts select UDP automatically and fall back to the SSH pipe when
the probe cannot complete. Interactive GUI connections bootstrap over
SSH so the UDP probe cannot add a multi-second main-loop stall, then
move the live attachment to UDP in the background. `sketerm ssh -u` (or
`transport = udp`) forces UDP: it does one SSH round to start
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
path is blocked, automatic mode continues over SSH (CLI commands also
report the fallback, with the reason). Forced UDP prints a warning
after 5 s and gives up after 15 s.

### Where UDP goes

The UDP leg targets whatever `ssh -G <host>` resolves the spec to, not
the string you typed, so `Host` aliases, `HostName` overrides and
`Match` blocks in `~/.ssh/config` are honoured — `sketerm ssh vastai`
sends its datagrams to the alias's real `HostName`. A host reached
through `ProxyJump`/`ProxyCommand` has no directly reachable address,
so UDP is skipped immediately and the connection goes over SSH rather
than burning the probe timeout.

Containers behind NAT port-mapping (Vast.ai, Docker `-p`, most cloud
sandboxes) need the pinned range above **and** an identity mapping:
the bootstrap announces the port it bound *inside* the container, and
nothing tells the client that the outside world reaches it on a
different number. Map the range straight through (`-p 60000-61000:60000-61000/udp`)
or UDP will announce a port that is not reachable and quietly fall
back to SSH.

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
- Kitty-graphics placements are snapshotted (12 MB retention budget
  per session, oldest evicted) and come back on reattach.

## Remote GUI apps (Wayland forwarding)

Any Wayland app started inside a durable session shows up as a
native window on the client desktop — `$WAYLAND_DISPLAY` in the
session points at the daemon itself, which relays the protocol over
the mux connection (so forwarded apps roam with UDP transports and
survive reattach like everything else). **Nothing extra to install
on either end**: the daemon is the display server, the sketerm GUI
is the compositor.

Supported today: windows (resizable, titled, with the app's icon),
keyboard + mouse, menus/popups, text clipboard both ways. Damage
tracking + zstd keep buffer traffic reasonable over a network.
Pixel transport accepts shm and opt-in linux-dmabuf (`--gpu`): LINEAR
buffers use direct mmap, while tiled/modifier-backed buffers are
imported through runtime-loaded EGL/GLES and normalized to BGRA before
crossing the mux transport. Missing runtime GPU import support leaves
the safe software/shm default unchanged. The current v3 path accepts
ARGB8888/XRGB8888 plus modifier-defined auxiliary planes; importability
still depends on the app and mux worker selecting compatible GPUs.
`SKETERM_MUX_NO_WAYLAND=1` disables forwarding entirely.

`sketerm app [-u] [-i] <host> <cmd>` is the one-shot form: it spawns
the app in a fresh durable session and hands it to the running sketerm
window to render. A sketerm window must already be open on this
desktop — it is the compositor.

`-i` (isolate) runs the session under a private `XDG_RUNTIME_DIR` with
the inherited D-Bus session bus dropped. Use it for **single-instance**
apps (pcmanfm and other libfm tools, anything built on
`GApplication` uniqueness): without it, a second `sketerm app <host>
<same-app>` from a different client finds the first copy already
running for that remote user and hands its window to it — so the new
window pops up on the *first* client's desktop, not yours. Isolation
gives the second copy its own session so it renders where it was
launched. The cost is that an isolated session no longer shares the
remote login's audio / notifications / portals; leave `-i` off for apps
that aren't single-instance (e.g. `weston-terminal`, most editors).

## Remote macOS apps (window streaming)

macOS apps have no forwardable display protocol (they speak private
Mach IPC to WindowServer), so a macOS host streams **pixels**: the
daemon captures each app window with ScreenCaptureKit and the
client renders it as a native window, with keyboard/mouse/scroll
injected back via CGEvents. App sessions on a Mac use this
automatically — same wire, same transports (ssh / mux socket /
roaming UDP), nothing to choose.

> **Setting up a Mac host?** `docs/macos-winstream-setup.md` is the
> complete copy-paste runbook (cert, deploy script, grants,
> troubleshooting). The summary below covers the same ground.

Setup is a one-time dance with three non-obvious macOS constraints
(all validated on hardware — frames + input + window-close confirmed
end to end). `dist/deploy-macos.sh` automates the repeatable part.

1. **A capture-capable daemon.** `zig build mux` ON the Mac.
   `sketerm-mux-portable` does not include capture (cross builds
   have no macOS SDK); neither does a Linux-built binary.
2. **A stable code-signing identity (do this once).** TCC pins a
   Screen Recording / Accessibility grant to the binary's *code
   signature*. Zig binaries are ad-hoc signed, so a rebuild changes
   the hash and the grant goes stale — re-granting every build.
   Fix it by signing with a self-signed cert, which pins the CERT
   (rebuilds re-signed with it keep the grant). Create it once:
   **Keychain Access → Certificate Assistant → Create a Certificate**
   → name `sketerm-dev`, **Self-Signed Root**, **Code Signing**.
   (Self-signed roots you create are trusted for your user
   automatically.)
3. **Deploy as a GUI-session LaunchAgent.** Run `dist/deploy-macos.sh`
   **from a Terminal in your GUI session** (not over SSH). It builds,
   signs with `sketerm-dev`, writes `~/Library/LaunchAgents/
   dev.sker.sketerm-mux.plist`, and bootstraps it into your session.
   Two constraints force this exact shape:
   - **WindowServer.** Capture's `SCContentFilter` makes in-process
     WindowServer calls. A daemon must run in the Aqua login session
     or it aborts (`CGS_REQUIRE_INIT`). An agent bootstrapped over
     SSH lands in the wrong audit session; one bootstrapped from your
     own session does not. (The daemon also self-promotes to a
     UIElement app to establish the connection — no Dock icon.)
   - **TCC attribution.** TCC blames the "responsible process". A
     daemon launched from a shell is attributed to the *terminal*
     (no grant → denied); a launchd agent is attributed to
     sketerm-mux itself. So it must be an agent, never a shell job.
4. **One-time TCC grants** (not scriptable, by design). The first
   capture attempt registers `sketerm-mux` — DISABLED — under
   System Settings → Privacy & Security → **Screen Recording**;
   the first input injection does the same under **Accessibility**.
   Enable both. Screen Recording takes effect on restart; only run
   `launchctl kickstart -k gui/$UID/dev.sker.sketerm-mux` after
   `sketerm mux list` confirms there are no sessions, because `-k`
   destroys them. Until granted, the client shows a notice
   window titled with these instructions and the daemon logs the
   exact failure — no silent hangs. If an entry was created against
   an *older* binary (stale hash), remove it with the **−** button
   first so the cert-signed binary re-registers.

After this, rebuilds are just `dist/deploy-macos.sh` again. It builds,
re-signs, and updates the LaunchAgent definition without replacing a
loaded daemon; the new binary applies after its natural exit or reboot.
No re-grant is needed because the grants ride the certificate.

Caveats: system apps (Calculator, TextEdit, …) carry launch
constraints on modern macOS and cannot be spawned as PTY children —
launch third-party apps or your own binaries directly, e.g.
`/Applications/Foo.app/Contents/MacOS/Foo`, from inside the
session. Windows are matched to the session by pid ancestry and by
controlling terminal, so apps launched from the session shell are
picked up even after re-parenting; apps launched via `open` (which
hands off to launchd) are not. Minimized windows close client-side
and re-open when restored. `SKETERM_WINSTREAM=stub` (test pattern)
and `=sck` (capture every session, not just app sessions) exist
for testing.
