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
- Filters: glob entries (type 0) become name patterns and mimetype
  entries (type 1) become mimetype patterns; both kinds of a filter
  are OR'd. A filter with no usable entry at all is dropped rather
  than turned into "all files". The filter dropdown sits in the
  dialog footer and always ends with an "All files" entry.
- `current_filter` selects a filter on open (one that is not in
  `filters` is appended so it can still be shown and left), and the
  filter the user accepted under is echoed back in the results as
  `current_filter` -- the caller's own variant, not a rebuild.
- `choices` has no widgets yet, but each choice's declared default is
  echoed in the results, so a caller reading them never sees a
  missing key.
- `parent_window` is imported: the dialog is a transient child of the
  calling window (see below).
- Cancelling the picker answers response 1; a `Close` on the request
  handle destroys the dialog and answers response 2. If the calling
  bus name disappears (a frontend crash), the dialog is destroyed the
  same way instead of being orphaned on screen.

## Portal-only picker rules

These two behaviours are opt-in per call and do NOT apply to
sketerm's own file dialogs:

- **The filter governs typed names.** In the plain picker the filter
  only decides what the listing shows (GTK's rule). Under the portal
  an application asked for particular file types, so a typed name
  that the active filter rejects is refused with a status-line
  explanation and an error-styled entry, instead of silently handing
  the app a `notes.txt` it said it could not read. Selecting
  "All files" in the dropdown lifts the rule, so it is never a dead
  end. Mimetype filters are matched against the type GIO guesses
  from the file NAME (never file content -- the file may be on
  another host and the GUI does not touch the disk), with GIO's
  subtype relation as a second chance (`text/x-zig` passes a
  `text/plain` filter).
- **Remote picks are refused where they happen.** The picker can
  browse SSH/UDP hosts; a portal consumer can only use local paths.
  Picking a remote file now raises "File is on another host" with an
  explanation and leaves the dialog open, rather than dropping the
  pick on the way out.

**Save targets are pre-flighted.** A typed save path whose parent
directory does not exist is refused in the dialog ("…/nosuchdir does
not exist, so nothing can be saved there") instead of being returned
for the consumer to fail on. Directories are never created
implicitly.

## Parent windows

`parent_window` arrives as `wayland:<xdg_foreign handle>` or
`x11:<hex xid>`; the picker applies it at realize time
(`src/ui/picker.zig`, `applyForeignParent`).

- **Wayland**: `gdk_wayland_toplevel_set_transient_for_exported`,
  GTK4's only foreign-parent importer.
- **X11**: GTK4 dropped GTK3's foreign windows and has no API for
  this, so the transient hint is set directly --
  `XSetTransientForHint(gdk_x11_display_get_xdisplay(display),
  gdk_x11_surface_get_xid(ours), parent_xid)`.

Both backends' symbols are resolved with `dlsym` at runtime (and
libX11 with `dlopen` only when an `x11:` handle actually arrives), so
a GTK built without one of the backends, or a session with no libX11,
degrades to an unparented dialog instead of a binary that will not
start. A handle for the wrong backend, or one the compositor cannot
import, is ignored the same way.

## Known limitations

- **Remote files are refused, not materialised.** Making a remote
  pick usable would mean copying or FUSE-mounting it locally and
  handing over that path -- a separate design decision (ownership,
  lifetime, cleanup), deliberately not taken here.
- **Wayland parenting needs a compositor with `xdg_foreign`.** The
  import path is exercised by the test rig, but sketerm's own
  compositor does not implement `zxdg_exporter_v2`, so GDK reports
  "Server is missing xdg_foreign support" there and the dialog stays
  unparented. The X11 branch is likewise not exercised by any test in
  this repo: X sessions are off-limits for GUI testing here (see
  CLAUDE.md), and no X11 desktop is available to the suite.
- `choices` are echoed at their defaults but not presented; the
  `writable` option is ignored (it only means anything to a
  document-portal-backed sandbox, which this backend does not
  implement). Advertised impl version: 2.

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
