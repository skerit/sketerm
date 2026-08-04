# Headless displays

`sketerm-mux display` provides a native Wayland display for GUI programs that
must run without a desktop. It is intended for game tests, browser tests,
rendering harnesses, and other places where X11 projects commonly use Xvfb.
It is independent of MCP. When `Xwayland` and `xwayland-satellite` are installed,
the same display also accepts X11-only applications in rootless mode.

## Replace xvfb-run

An Xvfb invocation such as:

```sh
xvfb-run -a -s '-screen 0 1024x768x24' ./run-render-test
```

maps to:

```sh
sketerm-mux display run --size 1024x768 -- ./run-render-test
```

`display run`:

- Generates a collision-resistant session name unless `--name` is given.
- Waits for the daemon to create and listen on the Wayland socket.
- Sets `WAYLAND_DISPLAY`, `XDG_RUNTIME_DIR`, and `XDG_SESSION_TYPE=wayland`.
- Automatically sets authenticated `DISPLAY` and `XAUTHORITY` values when the
  rootless X11 runtime is available. `--xwayland` makes it mandatory;
  `--no-xwayland` disables it.
- Sets `PULSE_SERVER` when the session audio hub is available.
- Clears an inherited `PULSE_SERVER` when no session audio hub is available.
- Forces deterministic software GL unless `--gpu` is given.
- Clears `WAYLAND_SOCKET`, and clears inherited `DISPLAY` and `XAUTHORITY` when
  rootless X11 is unavailable or disabled, so clients cannot select another
  display accidentally.
- Runs the argv after `--` directly, without another shell parse.
- Returns the command's exit status. Exec failures use 126 or 127.
- Forwards INT, TERM, HUP, and QUIT to the command process group, escalating
  to KILL after five seconds, then destroys the display.

The scoped runner has a 300-second fallback TTL by default. The TTL is not a
command timeout: it is paused while a mux viewer, external Wayland client, or
rootless X11 toplevel is active, and starts after the display becomes
unoccupied. Set `--ttl 0` to disable this fallback.

Use `--name NAME` when a human may attach to the live session from Sketerm.
The session remains visible while the command runs, but still belongs to the
runner and is destroyed when the command ends.

## Persistent displays

Use `create` when several independently launched processes need one display:

```sh
sketerm-mux display create --name render-rig --size 1024x768 --ttl 900 --json
sketerm-mux display inspect render-rig --json
sketerm-mux display destroy render-rig
```

The create reply contains:

- `session`: the explicit or generated name.
- `pid`: the daemon-host keeper process used to fence teardown identity.
- `output.width` and `output.height`: the effective virtual output mode.
- `gpu`: whether real-GPU mode is active.
- `xwayland`: whether rootless X11 compatibility is active.
- `environment`: variables to export for external processes.
- `unset_environment`: inherited variables that must be removed.

In GPU mode, `unset_environment` includes `LIBGL_ALWAYS_SOFTWARE`; merely
omitting that variable would leave a caller's inherited software override in
effect. With `--isolated`, it also includes `DBUS_SESSION_BUS_ADDRESS`.

Do not derive the Wayland or PulseAudio socket names. Broker and monolith
daemons intentionally use different internal naming schemes.

## Rootless X11

Rootless X11 is automatic when both `Xwayland` and xwayland-satellite 0.8.1 or
newer are on the daemon host's `PATH`. Native Wayland clients continue to use
`WAYLAND_DISPLAY`; X11-only clients use the reported `DISPLAY` and
`XAUTHORITY`. Use these controls when deterministic policy matters:

```sh
# Fail rather than silently run Wayland-only.
sketerm-mux display run --xwayland -- ./x11-test

# Never start the optional X11 stack.
sketerm-mux display run --no-xwayland -- ./wayland-test
```

Sketerm owns the display-number lock, filesystem and abstract Unix listeners,
and a random MIT-MAGIC-COOKIE-1 authority record with mode 0600. TCP listening
is disabled. It starts and supervises `xwayland-satellite`, which supplies the
X window manager and maps each X11 toplevel or popup to an ordinary Sketerm
`xdg_toplevel` or `xdg_popup`. Satellite's infrastructure connection does not
count as a renderer for display TTL; an abandoned display still expires.

The exported environment also sets `_JAVA_AWT_WM_NONREPARENTING=1`, as required
by xwayland-satellite for Java AWT windows. Satellite synchronizes X11 and
Wayland selections, including clipboard and PRIMARY. Cross-protocol drag and
drop is not covered by Sketerm's compatibility contract and should be tested
for the particular toolkit before relying on it.

This is rootless integration, not an X desktop nested inside a single window.
Every X11 application window appears separately to attached viewers and uses
the same controller lease as native Wayland windows. There is no visible root
desktop, panel, or reparenting window-manager frame.

`destroy` is display-only and waits for the Wayland socket to disappear. It
will not kill an ordinary terminal session with the same name.

## Xvfb differences

Xvfb is an X11 server with a virtual framebuffer. Sketerm is a native Wayland
compositor, so several X11 options have no direct equivalent:

| Xvfb concept | Sketerm behavior |
| --- | --- |
| `DISPLAY`, display numbers, `-a` | Native clients get an exact `WAYLAND_DISPLAY` path. Rootless X11 allocates a collision-safe local display number automatically. |
| `-screen 0 WxHxD` | `--size WxH`; depth is not configurable. The compositor advertises ARGB8888 and XRGB8888 shm formats. |
| `-dpi`, visual classes, `-pixdepths` | X11-only. Wayland clients use output scale and buffer formats. Display sessions currently start at scale 1. |
| Xauthority and `-ac` | Rootless X11 always uses a private random Xauthority cookie; access-control disabling is not offered. Wayland uses its Unix socket and runtime-directory permissions. |
| GLX, RANDR, RENDER, XTEST | Native clients use Wayland equivalents. X11 clients see the extensions implemented by the installed Xwayland build; Sketerm does not emulate or version them. |
| Root-window screenshots or `-fbdir` | Rootless windows are separate Wayland surfaces, not one composed X desktop framebuffer. Use the application's capture path or attach a Sketerm viewer. |
| X server TCP listening | Not provided. Display sockets are local Unix sockets; Sketerm's mux transport handles remote viewing. |

For SDL applications, `SDL_VIDEODRIVER=wayland` selects the native path and
`SDL_VIDEODRIVER=x11` selects rootless Xwayland. Likewise, toolkit-specific
backend variables can force one path when a test must not use automatic backend
selection. Keep Xvfb for tests that specifically require a rootful X desktop,
root-window composition, or server options/extensions absent from Xwayland.

`--size` configures the virtual output, not the initial application window.
Wayland toplevels still choose their own initial size unless their toolkit or
application requests fullscreen/maximized geometry.

## References

- Xvfb manual: <https://www.x.org/releases/current/doc/man/man1/Xvfb.1.xhtml>
- xvfb-run manual: <https://manpages.debian.org/unstable/xvfb/xvfb-run.1.en.html>
- X server startup and `-displayfd`: <https://man.archlinux.org/man/Xserver.1.en>
- Wayland display connection rules: <https://wayland.freedesktop.org/docs/html/apb.html#Client-classwl__display_1a37233bec2632b424ff447a4a2abe3c5d>
- XDG runtime directory requirements: <https://specifications.freedesktop.org/basedir-spec/latest/>
- xwayland-satellite: <https://github.com/Supreeeme/xwayland-satellite>
