# sketerm as an xdg-desktop-portal FileChooser backend (opt-in)

`sketerm portal` implements `org.freedesktop.impl.portal.FileChooser`
(OpenFile / SaveFile / SaveFiles), so any application that opens files
through the desktop portal — Flatpaks, browsers, Electron apps, GTK
apps using `GtkFileDialog` — can get the native sketerm picker instead
of the GTK/KDE one: remote hosts, places sidebar, thumbnails and all.

## This is strictly OPT-IN

Installing the package changes NOTHING about your file dialogs. The
two shipped files only make the backend *selectable*:

- `/usr/share/xdg-desktop-portal/portals/sketerm.portal` — declares the
  backend (D-Bus name `org.freedesktop.impl.portal.desktop.sketerm`,
  interface `org.freedesktop.impl.portal.FileChooser`).
- `/usr/share/dbus-1/services/org.freedesktop.impl.portal.desktop.sketerm.service`
  — lets the session bus start `sketerm portal` on demand.

xdg-desktop-portal only uses a backend the user (or the desktop's
defaults) names in `portals.conf`. To turn it on:

```ini
# ~/.config/xdg-desktop-portal/portals.conf
[preferred]
org.freedesktop.portal.FileChooser=sketerm
```

or keep a fallback chain (first candidate that owns its bus name wins):

```ini
org.freedesktop.portal.FileChooser=sketerm;gtk
```

then restart the portal frontend:

```sh
systemctl --user restart xdg-desktop-portal
```

Remove the line (and restart again) to go back — nothing else persists.

## Blast radius

Be aware of what the line above means before adding it: EVERY
portal-routed file dialog in your session now goes through sketerm's
picker — browsers' Save dialogs, Flatpak apps, screenshots tools, all
of them. If `sketerm portal` cannot start (broken install, missing
display), those dialogs fail until the portals.conf line is removed or
a fallback backend is listed after it. Keeping `;gtk` (or `;kde`) in
the chain only helps when sketerm's backend is *not running at all*;
it does not rescue an individual failed call. This is per-user
configuration; never ship it as a system default.

Only the FileChooser interface is claimed. Screenshot, screencast,
settings and every other portal keep using your desktop's backend.

## What the backend does

- `OpenFile` maps to the picker's open-file mode; `multiple` picks
  files (multi-select), `directory` picks a folder.
- `SaveFile` maps to save mode (`current_name` prefills the name
  entry; `current_file`'s directory/basename win when present;
  overwrite confirmation is the picker's own).
- `SaveFiles` asks for ONE destination directory and returns one
  `file://` URI per requested name (the caller writes the files; names
  containing `/` etc. refuse the call up front). No per-name overwrite
  prompt — per the spec the caller handles collisions.
- Filters: glob entries (type 0) become picker filters; mimetype
  entries (type 1) are ignored, and a filter with only mimetype
  entries is dropped rather than matching everything.
- Cancelling the picker answers response 1; a `Close` on the request
  handle destroys the dialog and answers response 2.

## Known limitations

- **Remote picks.** The picker can browse SSH/UDP hosts; a portal
  consumer can only use local paths. Remote selections are dropped
  from the reply, and a selection with no local member answers
  response 2 (the app shows its generic "dialog failed" path). The
  dialog itself starts on the local host.
- **Parent window.** The `parent_window` export handle (wayland:/x11:
  prefix) is not imported; the picker presents as a free-standing
  modal window, centered by the compositor, instead of a transient
  child of the requesting app's window.
- **Mimetype filters** (type 1 entries) are ignored — apps that send
  only mimetype filters get an unfiltered listing.
- `current_filter`, `choices` and the `writable` option are ignored;
  the reply carries `uris` only. Advertised impl version: 2.

## Trying it without touching your session

```sh
dbus-run-session -- sh -c '
  sketerm portal &
  sleep 1
  gdbus call --session \
    --dest org.freedesktop.impl.portal.desktop.sketerm \
    --object-path /org/freedesktop/portal/desktop \
    --method org.freedesktop.impl.portal.FileChooser.OpenFile \
    "/org/freedesktop/portal/desktop/request/x/t1" "" "" "Pick a file" "{}"
'
```

The call blocks until you accept/cancel the picker (or call `Close`
on the request path). Response: `(0, {uris: [...]})` on accept,
`(1, {})` on cancel.

Caveat when driving by hand: the `gdbus` tool's text-format
bytestring literals (`b'...'`, as used for `current_folder`/`files`)
have been observed to arrive CORRUPTED on the wire (glib
marshalling bug, confirmed with dbus-monitor — the bytes on the bus
are already garbage). Real portal frontends marshal these with
`g_variant_new_bytestring` and are unaffected; for manual testing
either omit bytestring options or use a small GDBus C client.
