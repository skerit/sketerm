# Configuration

Reference for `config.conf`, the file `src/config.zig` parses.
`data/sample.conf` is a commented starting point; this document is
the complete key list plus the structural rules a sample file cannot
express (what is per-profile and what is not, how prefix families are
keyed, precedence, reload semantics).

## Where the file lives

1. `--config <path>` on the command line. Highest priority; if it is
   unreadable a warning goes to stderr and the built-in defaults are
   used. Recorded process-wide, so every later re-read goes to the
   same file.
2. `$XDG_CONFIG_HOME/sketerm/config.conf`.
3. `$HOME/.config/sketerm/config.conf` when `XDG_CONFIG_HOME` is unset.

A missing file is not an error: every key has a baked-in default.
There is no `--no-config` flag.

The daemon (`sketerm-mux`) links the same parser, so keys that affect
session spawning (`shell`, `term`, `login_shell`, `scrollback`, the
`[lsp.*]` sections) are meaningful on the machine the session runs on.

## Syntax

```
key = value
```

- One key per line. Whitespace around the key and the value is
  trimmed.
- `#` starts a comment **only when it is the first non-blank
  character of the line**. There are no trailing comments, which is
  what keeps `#rrggbb` usable as a value.
- Blank lines are ignored.
- `[section]` headers switch the meaning of the lines that follow
  (see Sections).
- Unknown keys and unknown sections produce a stderr warning and are
  otherwise ignored, so a config written for a newer build still
  loads on an older one.
- A value that fails to parse warns with its line number and leaves
  that key at its previous value.
- Files larger than 64 KiB are truncated at that point with a
  warning.

### Value types

| Type | Accepted forms |
| --- | --- |
| bool | `true` / `false`, `1` / `0`, `yes` / `no`, `on` / `off` (case-insensitive) |
| int | decimal |
| float | decimal, e.g. `0.25` |
| string | unquoted, taken verbatim to end of line |
| path | string; a leading `~` or `~/` expands to `$HOME` (`~user` is not supported) |
| colour | `#RRGGBB`, `#RRGGBBAA`, `R,G,B` or `R,G,B,A` with components 0..255 |
| palette | exactly 16 colon-separated `#RRGGBB` entries |
| enum | one of the listed bare words |

## The one structural rule: app-level vs profile-level

Keys fall into two disjoint sets.

**Profile-level keys** are the pane-level settings bundle
(`ProfileSettings`): font, colours, shell and child environment,
scrollback, the pane's own shader, the pane border. They are valid
at the top level of the file AND inside a `[profile.<name>]` section.

**App-level keys** are everything else: window and tab chrome, mouse
behaviour, keybinds, rendering flags, bells, the file browser, editor
editing behaviour, the background image/opacity, the scrollbar, the
pane gap, quake geometry. They are valid **only at the top level**.
Putting one inside a `[profile.<name>]` section prints
`unknown profile key '<key>' (ignoring)` and does nothing. This is
the single most common mistake with this format.

`Config.settings` IS the Default profile: a profile-level key written
at the top level edits the Default profile, not some separate global.
`[profile.default]` is a legal alias for the top level and edits the
same bundle.

A named profile is a **complete copy**, not a patch. When the parser
reaches `[profile.dev]` it seeds the new profile from the Default
settings **as parsed so far** and then applies the section's keys on
top. There are no inherit sentinels and no fallback chain at apply
time. Two consequences:

- Top-level (Default) keys must appear **before** the profile
  sections that should inherit them. The serialiser always writes
  them in that order.
- Changing a Default key later does not change a profile that had
  already been seeded from a different value.

A pane resolves its bundle through `Config.profileSettings(name)`:
an empty name, the reserved name `default`, and any unknown name all
yield the Default settings, so a pane whose profile was deleted
degrades instead of dangling.

## Prefix-keyed families

Some settings are lists rather than single values. They are written
as a key prefix plus a name, and each family is described in full
further down.

| Family | Shape |
| --- | --- |
| `keybind.<action>` | `keybind.new_tab = <Control><Shift>t` |
| `hint.<name>.<field>` | `hint.jira.regex = [A-Z]+-[0-9]+` |
| `symbol_map.<name>` | `symbol_map.powerline = U+E0A0-U+E0A3 Symbols Nerd Font` |
| `shader_param.<name>` | `shader_param.glow = 0.55` |
| `light.<key>` / `dark.<key>` | `light.default_bg = #fdf6e3` |

`light.` / `dark.` are profile-level and therefore work both at the
top level and inside a profile section. The other four are app-level
and only work at the top level -- which includes a
`[platform.<name>]` section, since that is the top level made
conditional.

Within a family, a later line for the same name replaces the earlier
one (for `hint.<name>.*`, a later line for the same *field* replaces
that field; the rule itself is created by whichever field mentions it
first, and that is also the order rules are scanned in).

## Sections

| Header | Contents |
| --- | --- |
| `[profile.<name>]` | profile-level keys; `<name>` = `default` edits the Default bundle |
| `[platform.<name>]` | anything the top level accepts, applied only on `<name>` (`linux`, `macos`) |
| `[domain.<name>]` | `host`, `transport` |
| `[lsp.<name>]` | `command`, `args`, `languages`, `root_files`, `init_options`, `enabled` |
| `[mcp.<name>]` | `tools` (an MCP tool-exposure policy; a different namespace from `[profile.<name>]`) |

A section header with an unrecognised prefix warns and leaves the
following lines in the no-section (top level) state, so an unknown
future section does not silently strip data.

---

## Profile-level keys

Valid at the top level (= the Default profile) and inside
`[profile.<name>]`.

### Font

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `font` (alias `font_path`) | path | unset | Explicit font file. Wins over `font_family`. |
| `font_family` | string | unset | Resolved via fontconfig, e.g. `JetBrains Mono`. |
| `font_family_bold` | string | unset | Empty means "derive bold from `font_family`", which is wrong when you pair one family's regular with another's bold. |
| `font_family_italic` | string | unset | as above |
| `font_family_bold_italic` | string | unset | as above |
| `font_weight` | int | `0` | CSS weight 100..900 for the regular face. `0` = the font's own default (400). Selects the family's weight file AND sets the `wght` axis on a variable font, which is the only way to reach intermediate weights. A value outside 100..900 is a parse error, not a clamp. |
| `font_weight_bold` | int | `0` | Same, for the bold face (`0` = 700). |
| `font_features` | string | unset | OpenType features for HarfBuzz, whitespace/comma separated, CSS/kitty syntax: `-calt +ss01 zero cv05=3`. |
| `font_size` | int | `14` | Points. |
| `line_pad_px` (alias `line_spacing`) | int | `0` | Extra pixels of cell height. Negative tightens, clamped so the glyph still fits. |
| `padding` | float | `6.0` | Inner padding around the cell grid, in pixels. |
| `builtin_box_drawing` | bool | `true` | Draw box-drawing, block and Powerline characters from the cell rectangle instead of taking them from the font, so they tile with no seams. **This is on by default and is a visible change from earlier versions**; set `false` to get the font's own glyphs back. |

### Colours

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `default_fg` | colour | `#ebebeb` | |
| `default_bg` | colour | `#1a1a1a` | |
| `cursor_color` | colour | `#ffffff` | Ignored while `cursor_color_default` is on. |
| `cursor_color_default` | bool | `true` | Cursor takes the foreground colour (xterm/Terminator behaviour). |
| `scheme` | string | unset | Built-in preset: `sketerm`, `tango`, `solarized_dark`, `solarized_light`, `gruvbox_dark`, `gruvbox_light`, `nord`, `dracula`, `monokai`. Empty = no scheme. |
| `palette` | palette | unset | 16 colon-separated `#RRGGBB` (ANSI 0..15), Terminator's format. Overrides the scheme's palette. |

### Light / dark colour variants

`light.<key>` and `dark.<key>` override the flat colour of the same
name while the system colour scheme is in that state. They only take
effect with `auto_theme = true` (app-level); with `auto_theme` off,
the flat values are rendered exactly as written.

Overridable sub-keys: `default_fg`, `default_bg`, `cursor_color`,
`cursor_color_default`, `scheme`, `palette`. Anything left unset
falls through to the flat value, which is why a config written before
variants existed behaves identically.

Under `light` / `dark` there is also a built-in bottom layer -- the
`#1a1a1a` / `#ebebeb` pair `auto_theme` has always substituted -- so
a variant that sets only, say, `dark.default_bg` still gets the
built-in dark foreground rather than the flat one.

Both variants live in every profile, so a per-pane profile survives a
theme switch:

```
light.default_fg = #1a1a1a
light.default_bg = #fdf6e3
light.scheme     = solarized_light
dark.default_bg  = #002b36
dark.scheme      = solarized_dark
```

Note: clearing a variant field back to "inherit" is not expressible
in the file format, and neither is clearing a `palette` back to none.

### Shell and child environment

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `shell` | path | unset | Empty = the user's login shell. |
| `term` (alias `term_env`) | string | `xterm-256color` | Set to `xterm-kitty` to make tools that gate image preview on `$TERM` (yazi, lf, btop, chafa) use the Kitty graphics protocol, which sketerm implements. |
| `color_term` (alias `color_term_env`) | string | `truecolor` | |
| `login_shell` | bool | `false` | Prepends `-` to argv[0]. |
| `scrollback` | int | `10000` | Lines retained per pane. |

### Editor font

The editor face rides a pane, so its font is a pane-level choice.

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `editor_font_family` | string | unset | Proportional family via fontconfig. Empty = this profile's `font_family`, then built-in candidates. |
| `editor_font_size` | int | `0` | `0` = follow this profile's `font_size`. |

Editing *behaviour* (`editor_tab_width`, wrap, LSP, ...) is
app-level -- see below.

### Pane presentation

Per-profile so a profile can mark its panes: a red border on a `root`
or `prod` profile is the point. Lengths are framebuffer pixels, the
same unit as `padding`.

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `pane_border_width` | float | `2.0` | Clamped 0..32. 0 = no border. |
| `pane_border_color_active` | colour | `#668cd9bf` | Focused pane. |
| `pane_border_color` | colour | `#00000000` | Unfocused pane; alpha 0 draws nothing. |
| `pane_corner_radius` | float | `0` | Clamped 0..64. An alpha cut on the composited pane, so the corners reveal what is behind. Non-zero forces the post-process pass on. |

Note that the *gap between* panes (`pane_gap`, `pane_gap_color`) is
app-level, not per-profile: one CSS provider styles every GtkPaned in
the window and the gap belongs to no single profile.

### Shader

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `custom_shader` | path | unset | Shadertoy-style fragment shader defining `mainImage`; `iChannel0` is the rendered frame. A compile error disables the pass, it never blanks the pane. |

`custom_shader_animation` and the `shader_param.*` family are
app-level.

---

## App-level keys

Valid only at the top level.

### Cursor

| Key | Type | Default | Values |
| --- | --- | --- | --- |
| `cursor_shape` | enum | `block` | `block`, `underline`, `bar` |
| `cursor_blink` | bool | `true` | |
| `cursor_blink_ms` | int | `500` | One half-cycle, so 500 = a full blink per second. |
| `cursor_trail` | bool | `false` | Animated trail between the cursor's old and new cell. |
| `cursor_trail_ms` | int | `300` | Trail duration, `30`..`2000`. Out of range is a parse error. |

The trail is a quad spanned by four spring-driven corners: the ones
leading the movement snap to the new cell while the trailing one lags,
so the cursor stretches along its path and then contracts. It is drawn
in the active profile's cursor colour, under the cursor itself.

`cursor_trail_ms` is a deadline, not just a time constant — the trail
is always gone that long after the cursor last moved. That matters
because the animation is the only thing in a pane that redraws on a
timer: the pane runs a 60 fps GLib timeout while a jump is in flight
and drops it the frame the trail settles, leaving no timer and no
frame-clock tick behind. A pane whose cursor is not moving never
schedules anything, including a pane sitting next to one that is.

The trail is suppressed, and teleports rather than animating on its
next move, whenever drawing it would be misleading: on an unfocused
pane, while scrolled back, in copy mode, while the cursor is hidden
(DECSET 25), and across any event that replaces the viewport under the
cursor — a full-screen erase, an alternate-screen switch (opening or
leaving `vim`, `less`, …), a resize, or a session reattach.

### Text blending

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `text_blending` | enum | `native` | `native`, `linear`, `linear_corrected`. `linear-corrected` also parses. |

Which colour space antialiased glyph coverage is blended in. sRGB
values are not proportional to light — `128` is about 21% of the light
of `255`, not half — so blending the encoded values directly, which is
what every terminal has always done, makes partially covered edge
pixels come out too dark. The visible symptoms are a dark fringe along
glyph edges where complementary colours meet (red on green is the
classic) and light-on-dark text reading thinner than it should.

`native` keeps that behaviour, and is the default: font rasterisation
has been tuned against gamma-space blending for decades, so correcting
it changes how every glyph looks. `linear` blends in linear light,
which removes the fringing but shifts apparent weight — dark text on a
light background thins, light text on a dark one thickens.
`linear_corrected` applies a correction on top so the perceived weight
lands back where `native` had it while keeping the fringe fix; it is
the mode to try first.

Both linear modes render the pane through an offscreen linear target,
since a `GtkGLArea`'s framebuffer is a hardcoded `GL_RGBA8` texture
that cannot be asked for an sRGB format. `native` draws straight to
that framebuffer and costs nothing extra.

### Behaviour

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `bracketed_paste` | bool | `true` | |
| `modify_other_keys` | int | `0` | `0` off, `1` basic, `2` full. Anything higher is a parse error. |
| `word_chars` | string | `-_.,/?:@&=+%~` | Extra characters counted as part of a word for double-click selection, on top of alphanumerics. |
| `smart_copy` | bool | `true` | With no selection, Ctrl+Shift+C forwards Ctrl+C instead of doing nothing. |
| `scroll_on_output` | bool | `false` | Snap to the bottom on any output, not just on keystroke. |
| `exit_action` | enum | `close` | `close`, `restart`, `hold` (keep the pane with an exit-status banner). |
| `shell_integration` | bool/enum | `true` | Accepts `auto` (= true) and `off` (= false) as well as the bool forms. Injects the OSC 7/133 scripts into zsh/fish/bash at spawn. |
| `notify_command_secs` | int | `15` | Desktop-notify when a command in a non-visible pane finishes after at least this many seconds. `0` = off. Needs OSC 133. |
| `track_tab_activity` | bool | `true` | Per-tab activity indicator, computed in the event drain so it works for unfocused tabs. |
| `inactive_warn_secs` | int | `60` | Silence before a tab's inactivity warning fires. The toggle itself is per-tab (right-click a tab); this is the shared threshold. |
| `tab_ack_delay_secs` | float | `1.0` | Clamped 0..6. How long a tab must stay selected before viewing it clears its inactivity warning. |
| `image_memory_mb` | int | `320` | Per-pane target for retained decoded-image memory; past it the oldest images are evicted FIFO. It is a retention budget, not a per-image size limit: a single image larger than the whole budget still renders (the hard per-image ceiling is 256 MB and does not move with this key). `0` = unlimited. |
| `config_auto_reload` | bool | `true` | See Reload semantics. |
| `clipboard_read` | bool/enum | `false` | Accepts `allow` / `deny` as well as the bool forms. Allows apps to READ the clipboard via OSC 52 query. Off by default because anything on the PTY, including remote programs, could exfiltrate it. |
| `search_case_sensitive` | bool | `false` | Default for the search box; the actual default is smart-case unless this or Ctrl+I overrides. |
| `auto_url_detect` | bool | `true` | Underline and open plain http(s) URLs. OSC 8 hyperlinks win where both apply. |
| `gtk_theme` | string | unset | Name of a GTK theme whose `gtk-4.0/gtk.css` is applied over libadwaita's stylesheet. Empty = honour the session theme. |

### Rendering

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `ligatures` | bool | `true` | HarfBuzz shaping. |
| `bidi` | bool | `true` | fribidi reorder; pure-ASCII lines skip it. |
| `auto_theme` | bool | `true` | Follow AdwStyleManager light/dark. Off honours `default_fg` / `default_bg` exactly and disables the `light.` / `dark.` variants. |
| `graphics_offload` | bool | `true` | GtkGraphicsOffload for pane GL content. Automatically suspended across a whole window while any pane continuously renders an animated shader or Kitty image. |
| `allow_bold` | bool | `true` | Whether the bold attribute affects rendering at all. |
| `bold_is_bright` | bool | `true` | Bold also lifts palette 0..7 to 8..15 (xterm convention). |
| `minimum_contrast` | float | `1.0` | Clamped 1..21. Minimum WCAG contrast between text and its cell background; text below it snaps to white or black. `1.0` = off. |
| `inactive_darken` | float | `0.2` | Clamped 0..1. Uniform darken of an unfocused pane's final composited image, so colour relations are preserved. |
| `inactive_desaturate` | float | `0.0` | Clamped 0..1. Blend an unfocused pane toward luma. |
| `custom_shader_animation` | bool | `false` | Redraw continuously so `iTime` advances for config and manually selected shaders. Named presets keep their own `animate` value. Any effective animated shader suspends graphics offload across its whole window because the panes share one frame clock. |
| `browser_max_fps` | int | `0` | Ceiling on how often a browser pane's page repaints. `0` = follow the output the window is on. Anything else must be `5`..`1000`; out of range is a parse error. |
| `web_discard_minutes` | int | `30` | Minutes a web pane may stay off screen before its page is discarded outright (the browser is destroyed and the pane keeps its last frame, dimmed). `0` = never. |
| `web_popup_policy` | enum | `block-gestureless` | What a browser pane does with a popup a page asks for: `block-gestureless`, `allow`, `block-all`. Anything else is a parse error. |
| `web_download_ask` | bool | `true` | Whether a browser pane's download raises a save dialog. `false` auto-accepts into `~/Downloads` under the page's suggested name (uniquified on collision). The save dialog can also pick a `host:` location: the file downloads locally first, then hands off to that host's daemon as an ordinary transfer. |
| `web_search_engine` | string | `https://duckduckgo.com/?q={q}` | Search-engine URL template for address-bar input that is not a URL. `{q}` is replaced by the percent-encoded query. Must be an http(s) URL containing `{q}`; anything else is a parse error. |

`browser_max_fps` is a CEILING, not a target. A browser pane paints
nothing at all while its page is unchanged, and a background tab's page
is not painted at all, so lowering this saves nothing on an idle page —
it only limits an animating one (video, canvas, a scrolling feed).

The engine paces itself; this key is the ceiling sketerm hands it. The
default follows the display because the engine cannot know which output
a window is on: sketerm ships the cap clamped to that output's real
refresh, so a 120Hz or 165Hz panel is used fully and dragging a window
between differently refreshing outputs re-paces it with no config
change. Set a number here to cap a browser pane below the display (a
battery-minded `30`), never to raise it above one — no cap can make a
view exceed its own output's refresh.

`web_discard_minutes` is about MEMORY, not about painting. A web pane
that is not on screen already paints nothing at all — but the browser
engine behind it still holds its renderer process, its JavaScript heap
and its decoded images. Past this many minutes off screen, sketerm asks
the helper to destroy that browser entirely (`view_discard`, helper
capability `discard`). The pane keeps showing the LAST frame it
received, dimmed, and the page comes back the moment the tab is shown,
focused or navigated.

The price is a RELOAD: the revived page starts a fresh session at the
same address, so its navigation history (back/forward) and anything
typed into a form but not submitted are gone. That is why the default
is a conservative 30 minutes rather than a couple, and why `0` (never
discard) is a reasonable choice for anyone who leaves half-filled forms
in background tabs. The **Discard Background Web Tabs** command in the
palette (action `web_discard_background`) does the same thing on
demand, whatever this key says. A helper too old to advertise `discard`
never receives the frame, and every web pane then behaves exactly as it
did before this key existed.
`web_popup_policy` decides what happens when a page calls
`window.open` or follows a `target=_blank` link. The browser helper
never opens a popup itself — it cancels the request and reports it — so
this key is the whole policy:

- `block-gestureless` (default): a popup produced by a real user
  interaction opens as a new web tab, exactly as before. One the page
  produced on its own is BLOCKED and offered as a toast naming the host,
  with an `Open` button that opens it after all. That flag is what
  separates a link the user clicked from an advertising pop-under.
- `allow`: every popup opens, the pre-policy behaviour.
- `block-all`: every popup becomes a toast, gesture or not.

A browser helper older than the policy reports no gesture flag, and a
missing flag counts as a gesture — such a helper keeps opening every
popup rather than having all of them blocked.

`web_search_engine` is used whenever address-bar input is neither an
explicit URL nor something that looks like a host: the query is
percent-encoded and substituted for `{q}`. Examples:

```
web_search_engine = https://www.google.com/search?q={q}
web_search_engine = https://www.startpage.com/sp/search?query={q}
```

A template that lacks `{q}` or does not start with `http://`/`https://`
is rejected as a bad line (default kept), so a typo cannot turn every
search into a broken navigation.

`inactive_fg_dim` and `inactive_bg_dim` are retired per-cell dim keys.
They are still accepted and ignored, so old files do not warn; use
`inactive_darken`.

### Bell

| Key | Type | Default |
| --- | --- | --- |
| `bell_audible` | bool | `false` |
| `bell_visible` | bool | `true` |
| `bell_urgent` | bool | `true` |

### Window and tabs

| Key | Type | Default | Values |
| --- | --- | --- | --- |
| `tab_position` | enum | `top` | `top`, `bottom` |
| `close_button_on_tab` | bool | `true` | |
| `show_tab_bar` | bool | `true` | Start with the AdwTabBar hidden by setting false; the `toggle_tab_bar` action flips it at runtime. |
| `show_tab_sidebar` | bool | `false` | Whether a new window opens with the vertical tree-style tab sidebar shown. Visibility is then PER WINDOW: the `toggle_tab_sidebar` action (key, Tab menu, hamburger, palette) flips only the window it was invoked in and does not write this setting back, so a config reload never pushes one window's choice into the others. Flipping the switch in a window's Preferences hands that window back to the setting. `tab_collapse` / `tab_expand` fold a tab's children, and a row drags like a real tab: onto another row to nest under it, between rows to reorder, onto another window's sidebar or tab strip to move it there, and onto nothing to open it in a new window. While it is shown it is also the tab surface for BROWSERS: it lists the pages open inside the focused browser rather than mirroring the window's tabs, and "new tab" opens a page there. Hide it and a browser goes back to its own in-pane tab strip, with new tabs becoming window tabs again. |
| `tab_sidebar_width` | int | `240` | Width of that sidebar in logical px, 120..800. Dragging its divider writes this back. |
| `web_store_socket` | path | (empty) | Daemon socket holding browsing history and bookmarks. Empty resolves at connect time: `$SKETERM_MUX_SOCKET`, else the per-user daemon. Point it at a forwarded socket (`ssh -L`) to share ONE history across machines. Not a remote dialer — the socket must be reachable as a path. |
| `filter_list` | url | (none) | An `http://` or `https://` content-blocking filter list to keep up to date, EasyList syntax. Repeat the key for several lists; file order is meaningful (a later list can whitelist what an earlier one blocked). Fetched by the browser helper into `$XDG_CONFIG_HOME/sketerm/filters/` as `sub-<name>-<hash>.txt`, alongside any list you drop in by hand; those are never touched. With no `filter_list` set, filtering makes no network request at all. |
| `filter_update_hours` | int | `24` | How often a subscribed list is refetched. `0` stops updating; lists already on disk keep working. A body that does not look like a filter list (a captive portal, an HTML error page) is refused rather than written over a working one. |
| `tab_close_parent` | enum | `promote` | Closing a tab that has child tabs: `promote` lifts the children one level (TST's default) or `close-subtree` closes them with it. Applies to browser pages too. |
| `tab_child_insert` | enum | `last` | Where a new child tab lands among its siblings: `last` or `first`. |
| `always_on_top` | bool | `false` | |
| `new_tab_after_current` | bool | `false` | Insert new tabs after the focused one instead of appending. |
| `confirm_close` | enum | `multiple` | `never`, `multiple` (only when more than one pane is being lost), `always` |
| `show_titlebar` | bool | `false` | Per-pane title bar carrying the OSC 0/1/2 title. |
| `title_active_fg` | colour | `#ffffff` | |
| `title_active_bg` | colour | `#c80003` | |
| `title_inactive_fg` | colour | `#000000` | |
| `title_inactive_bg` | colour | `#c0bebf` | |

### Title format

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `tab_title_template` | string | `{{ TITLE }}` | Format of a tab label. The default is the OSC 0/2 title verbatim. |
| `window_title_template` | string | *(empty)* | Format of the window title, from the FOCUSED pane. Empty leaves the window titled `sketerm` (or `Sketerm Files`), which is the historical behaviour. |

Both are app-level, not per-profile: a tab strip mixing two title
*formats* reads as a bug, and the window title has no profile to
belong to. Manual titles still win — a tab renamed via **Rename Tab…**
is locked and ignores the template until the lock is cleared (rename
it to an empty string).

Placeholders are `{{ NAME }}`, case-insensitive, and `||` gives a
fallback chain (`{{ TITLE || PROGRAM }}` uses the first non-empty).
The set is closed:

| Placeholder | Resolves to |
| --- | --- |
| `title` | The OSC 0/2 title, exactly as the application set it. |
| `program` | Foreground process on the pane's pty (`nvim`, `ssh`, `bash`). Sampled by the daemon off the back of terminal output, so it needs no shell integration. |
| `absolute_path` | Working directory (OSC 7, or the daemon's `/proc` lookup). |
| `relative_path` | The same path with `$HOME` folded to `~`. |
| `columns`, `lines` | Current grid size. |
| `index` | 1-based tab position. |
| `session` | Mux session name; empty for a plain local pane. |
| `profile` | Active profile name; empty on the Default profile. |
| `zoom` | `zoom` while the pane is zoomed, otherwise empty. |

**Unknown placeholders are rejected at parse time.** The set is closed,
so `{{ TITEL }}` can only be a typo; sketerm warns (naming the bad
placeholder and listing the valid ones) and falls back to the default
for that key. The rest of the config still loads — one bad line never
costs you the file.

**Empty values do not leave dangling separators.** A placeholder that
resolves to nothing takes one adjacent punctuation-only literal with
it — the one after it, or the one before it if it is last:

| Template | Result |
| --- | --- |
| `{{ PROGRAM }} - {{ RELATIVE_PATH }}` with no path | `nvim` |
| `{{ PROGRAM }} - {{ RELATIVE_PATH }}` with no program | `~/src/sketerm` |
| `{{ INDEX }} - {{ PROGRAM }} - {{ TITLE }}` with no program | `3 - vim README.md` |
| `{{ PROGRAM }} ({{ COLUMNS }}x{{ LINES }})` with no size | `nvim` |

Literals carrying letters or digits are treated as text you meant and
are kept — except when wedged between two empty placeholders, which is
the `x` in `{{ COLUMNS }}x{{ LINES }}`. Brackets are not paired, so
`[{{ ZOOM }}] {{ TITLE }}` leaves a stray `[` on an unzoomed pane;
write `{{ ZOOM }} {{ TITLE }}` instead.

### Split separators

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `pane_gap` | float | `4.0` | Clamped 1..64, logical pixels. Keep it a multiple of 4: at fractional surface scales an odd separator pushes a pane off the device-pixel grid and GtkGraphicsOffload then rejects every frame. |
| `pane_gap_color` | colour | `#353535` | What shows through the gap. |

### Overlay scrollbar

Drawn by the renderer inside the pane, not a widget, so it steals no
column. Window-level rather than per-profile: it is chrome, and a
scrollbar that came and went with a pane's profile would be a trap.

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `scrollbar` | enum | `auto` | `never` (not drawn, not interactive), `auto` (drawn once there is scrollback), `always`. There is no timed fade-out. |
| `scrollbar_width` | float | `4.0` | Clamped 0..64 framebuffer pixels; `0` also disables it. |
| `scrollbar_trough_color` | colour | `#8080802e` | |
| `scrollbar_thumb_color` | colour | `#8080804d` | Thumb while the view sits at the live bottom. |
| `scrollbar_thumb_active_color` | colour | `#668cd9b3` | Thumb while scrolled back. |

### Mouse

| Key | Type | Default | Values |
| --- | --- | --- | --- |
| `mouse_autohide` | bool | `true` | Hide the pointer while typing. |
| `copy_on_selection` | bool | `false` | Copy to PRIMARY on selection end. |
| `clear_select_on_copy` | bool | `false` | Drop the selection after Ctrl+Shift+C. |
| `disable_mouse_paste` | bool | `false` | Kill switch for middle-click PRIMARY paste; still wins over `mouse_middle_click`. |
| `disable_mousewheel_zoom` | bool | `false` | Disable Ctrl+wheel font zoom. |
| `link_single_click` | bool | `false` | Open OSC 8 links on a plain click instead of Ctrl+click. |
| `mouse_middle_click` | enum | `paste_primary` | `menu`, `paste_primary`, `paste_clipboard`, `none`. `menu` is not meaningful here and behaves as `none`. |
| `mouse_right_click` | enum | `menu` | Same set; PuTTY users want `paste_clipboard`. |

Both click actions apply only while the running app is not in
mouse-report mode.

### Keyboard hints

Hint mode (Ctrl+Shift+E by default) labels every match on screen and
activates the one whose label you type.

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `hint_editor` | string | unset | Command used when a path hint's file exists: either a template with `{file}` / `{line}` / `{col}` (`code -g {file}:{line}:{col}`) or a bare command taking `+line file` (`nvim`). Empty = `$EDITOR` / `$VISUAL`, and with neither set the match is copied to the clipboard. |
| `hint_alphabet` | string | unset | Label characters, in the order labels are handed out. Empty = the built-in home-row-first set (`asdfghjklqwertyuiopzxcvbnm`). Ignored (with the built-in used instead) if it is shorter than 2 or longer than 64 characters, contains a duplicate, or contains anything outside printable ASCII. |
| `hint_multiple` | bool | `false` | Start hint mode in multi-select, where each label appends its match instead of activating and closing. Tab toggles it in-mode either way. |

#### `hint.<name>.<field>` rules

User-defined rules are scanned **before** the built-in URL / path /
hash scanners, so a rule can claim text those would have taken. Rules
apply in the order their names first appear in the file.

| Field | Type | Notes |
| --- | --- | --- |
| `regex` (alias `pattern`) | string | POSIX extended regular expression, matched against each visible row's text. An invalid pattern disables just that rule. |
| `action` | enum | `open`, `copy` (default), `paste`, `select`, `command`. `open` hands URLs to the desktop and existing files to the editor. |
| `command` | string | Shell command for `action = command`. `{match}` is substituted with the matched text, shell-quoted. |

```
hint.ticket.regex   = [A-Z]{2,}-[0-9]+
hint.ticket.action  = command
hint.ticket.command = xdg-open https://jira.example.com/browse/{match}
```

### `symbol_map.<name>`

Routes a codepoint range to a specific font family. Consulted before
the primary face, so the mapped font wins even where the main font
has glyphs of its own in that range. App-level rather than
per-profile: this is glyph coverage, which does not sensibly differ
between two panes of one session.

```
symbol_map.powerline = U+E0A0-U+E0A3 Symbols Nerd Font
symbol_map.tick      = U+2713 DejaVu Sans
```

The value is `<lo>[-<hi>] <family>`. The `U+` prefix is optional on
either end (`0x` is also accepted), a single codepoint means a
one-entry range, and `hi < lo` is an error. `<name>` is just a label
so a later line can replace the entry.

### `shader_param.<name>`

Overrides for the tunable uniforms a custom shader declares
(RetroArch `#pragma parameter` lines plus sketerm's `//@color`). The
value is a float, or `#RRGGBB` for a vec3 colour parameter. Names are
capped at 31 characters. Uploaded every frame, so a reload re-tunes
live without recompiling.

```
shader_param.glow     = 0.55
shader_param.phosphor = #ffb333
```

### `keybind.<action>`

`<action>` is the action name; the value is a GTK accelerator string
(`<Control><Shift>t`). An **empty value unbinds** that action. A
missing entry keeps the default binding. Unknown action names and
unparseable accelerators warn on load and are skipped; an accelerator
that shadows another binding warns too.

Action names (stable across versions, from `src/ui/input.zig`):

```
new_tab close_tab next_tab prev_tab copy paste split_h split_v
font_inc font_dec font_reset search_open cross_search attach_all
save_layout save_layout_as save_default_layout load_layout
prompt_prev prompt_next pane_next pane_prev prefs_open
broadcast_cycle restore_closed_tab toggle_pin_tab toggle_tab_bar
reload_config launch_app app_windows
goto_tab_1 goto_tab_2 goto_tab_3 goto_tab_4 goto_tab_5
goto_tab_6 goto_tab_7 goto_tab_8 goto_tab_9
duplicate_tab detach_tab configure_shader shader_preset_pick
apply_profile show_scrollback new_durable_tab new_browser_tab
new_browser_split new_web_tab new_web_split web_reader
close_pane toggle_browser_face new_editor_tab
new_editor_split toggle_editor_face mux_detach paste_clipboard
new_browser_split close_pane toggle_browser_face new_editor_tab
new_editor_split toggle_editor_face web_discard_background
mux_detach paste_clipboard
copy_selection
copy_screen copy_scrollback copy_command_output
select_command_output interrupt_or_copy clear_and_scrollback
clear_scrollback scrollback_page_up scrollback_page_down
scrollback_top scrollback_bottom command_palette hints_open
copy_mode zoom_pane
toggle_tab_sidebar tab_collapse tab_expand tab_tree_next tab_tree_prev
```

The tree-style-tab actions use platform-specific defaults:

| Action | Linux | macOS | Meaning |
| --- | --- | --- | --- |
| `toggle_tab_sidebar` | `Ctrl+Shift+Alt+B` | `Cmd+Shift+Option+B` | Show or hide the tree sidebar. |
| `tab_collapse` | `Ctrl+Shift+Alt+H` | `Cmd+Shift+Option+H` | Hide (collapse) the selected node's children. |
| `tab_expand` | `Ctrl+Shift+Alt+E` | `Cmd+Shift+Option+E` | Expand the selected node. |
| `tab_tree_next` | `Ctrl+Alt+PageDown` | `Cmd+Option+PageDown` | Select the next visible tree node. |
| `tab_tree_prev` | `Ctrl+Alt+PageUp` | `Cmd+Option+PageUp` | Select the previous visible tree node. |

They are also in the Tab menu, the window hamburger and the command
palette, and work while a sidebar row has keyboard focus. macOS avoids
the Control+Option modifier pair reserved by VoiceOver. The four
navigation actions always follow the visible tree:
the focused browser's pages while the sidebar lists them, and the
window's tab tree otherwise, including while the sidebar is hidden.

### File browser

| Key | Type | Default | Values |
| --- | --- | --- | --- |
| `files_default_view` | enum | `details` | `details`, `compact`, `icons`, `miller`. Per-folder view memory still wins for folders the user has adjusted. |
| `files_show_hidden` | bool | `false` | |
| `files_confirm_delete` | bool | `true` | Ask before a permanent delete. |
| `files_verify_copy` | bool | `false` | Hash-compare each copied file against its source before the copy installs. |

### Text editor (behaviour)

App-level on purpose: the same person wants the same indentation and
wrap default in every window, and a document opened from the browser
must not indent differently because of the pane it landed in. The
editor *font* is per-profile.

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `editor_tab_width` | int | `4` | 1..16. |
| `editor_insert_spaces` | bool | `true` | False inserts a real tab. |
| `editor_soft_wrap` | bool | `false` | Initial state for new editor tabs; per-tab from there. |
| `editor_line_numbers` | bool | `true` | |
| `editor_highlight_current_line` | bool | `true` | |
| `editor_syntax` | bool | `true` | Tree-sitter highlighting. |
| `editor_bracket_match` | bool | `true` | |
| `editor_folding` | bool | `true` | |
| `editor_fold_indent_fallback` | bool | `true` | Derive folds from indentation for files with no grammar. |
| `editor_theme` | string | `dark` | `dark` or `light`; anything unknown falls back to `dark`. |
| `editor_crash_recovery` | bool | `true` | Snapshot unsaved buffers to `$XDG_STATE_HOME/sketerm/editor-recovery.d`. |
| `editor_git_gutter` | bool | `true` | Per-line change markers against HEAD, computed on the file's own host. |
| `editor_outline` | bool | `false` | Open the symbol outline with every editor face; Ctrl+Shift+O still opens it per face. |
| `editor_project_markers` | string | unset | Comma-separated marker filenames identifying a project root. Empty = the built-in list. |
| `editor_project_search_max_files` | int | `4000` | Cap on files a project-wide search will read. |
| `editor_lsp` | bool | `true` | Master switch for the language-server client. Off means no server is ever spawned. |
| `editor_lsp_diagnostics` | bool | `true` | Squiggles and gutter markers; off keeps the rest of LSP working. |
| `editor_lsp_debounce_ms` | int | `250` | Delay after the last keystroke before `textDocument/didChange` is flushed. A feature request always flushes first regardless. |

### Forwarded apps and remote sessions

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `app_view` | enum | `window` | `window` (free-floating; the tab keeps the app log and a raise banner) or `tab` (embedded interactively). Pop-out is available either way. |
| `app_keyboard_layout` | string | unset | xkb layout for forwarded-app session keyboards: `us`, `gb`, `fr`, `be`, `de`. Set it to YOUR physical layout -- keystrokes pass through as raw keycodes and the app decodes them with this keymap. Empty = `us`. |
| `gpu_apps` | string | unset | Comma-separated app names always launched with GPU rendering (linux-dmabuf instead of software GL), matched case-insensitively against the .desktop `Name` or the `Exec` binary's basename: `Blender, mpv`. |
| `mux_udp_port_range` | string | unset | `lo:hi` passed to the remote UDP bootstrap; pin it when a firewall sits in front of the host (`60000:61000`). Validated at load. Empty = ephemeral port. |
| `input_method` | enum | `auto` | `simple` = GTK's in-process compose tables (dead keys always work, no IME); `multi` = the per-display IM module (ibus/fcitx, but on Wayland that module has no compose engine); `auto` picks `multi` only where an input method is visibly configured. Under `auto` the terminal always resolves to `simple`; the editor and the app host follow the heuristic. An explicit value applies to every face. Applies to faces created after the change. |

### Background layer

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `background_opacity` | float | `1.0` | Clamped 0..1. Needs compositor support for per-window alpha. Blur is not reachable from GTK4; set it with a compositor window rule. |
| `background_image` | path | unset | PNG/JPEG, drawn cover-cropped behind the cell grid. Wins over the gradient. |
| `background_image_opacity` | float | `0.3` | Clamped 0..1. Keep it low: text on the default background sits directly on the image. |
| `background_gradient_from` | colour | transparent | The gradient is active only when both colours have alpha > 0. |
| `background_gradient_to` | colour | transparent | |
| `background_gradient_angle` | float | `90` | Degrees; 0 = left to right, 90 = top to bottom. |

### Quake mode

Applied to the primary window when `quake_enabled` is on; `sketerm
--toggle` raises or hides the running instance.

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `quake_enabled` | bool | `false` | With it on, the primary window is sized from the monitor instead of the 1000x700 default. |
| `quake_monitor` | string | `active` | `active` (the monitor the window is on), `primary`, a 0-based index, or a connector name such as `DP-1`. Anything unrecognised resolves to `active`. |
| `quake_edge` | enum | `top` | `top`, `bottom`, `left`, `right`. **Parsed, serialised, and currently moves nothing** -- see below. |
| `quake_width_percent` | float | `100.0` | Clamped 1..100, of the target monitor. |
| `quake_height_percent` | float | `50.0` | Clamped 1..100. |

Platform caveats, stated plainly because the intended behaviour and
the actual behaviour differ:

- **`quake_edge` does not move the window.** Wayland does not permit
  a client to position its own toplevel, and GTK4 removed
  `gtk_window_move` on every backend, so there is no call sketerm can
  make to push the window against an edge. The key is recorded so a
  compositor window rule (or a future layer-shell backend) can
  consume it. Today, pin the window with a KWin or Mutter rule.
- **Monitor targeting is exact only at 100% x 100%.** That is the one
  case that goes through `gtk_window_fullscreen_on_monitor`, the only
  GTK4 call that names a monitor. At any smaller size sketerm can
  only set the window size and the compositor decides where it lands.
- **Percentages are of the full monitor rectangle, not the work
  area.** `gdk_monitor_get_workarea` is gone in GTK4, so panels and
  docks are not subtracted.
- **GTK4 has no primary-monitor concept**, so `quake_monitor =
  primary` resolves to the display's first monitor.

### Profile selection

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `default_profile` | string | unset | Profile new panes spawn with. Empty or `default` = the Default settings. |

Splits inherit the focused pane's profile. "Apply Profile to Pane"
(right-click or the palette, action `apply_profile`) restyles a live
pane.

---

## `[platform.<name>]` -- per-operating-system overrides

One config file that behaves differently on two machines. The
section's lines are exactly the lines you would write at the top
level, and they are applied **only when `<name>` is the operating
system this build runs on**.

```
font_family = JetBrains Mono
font_size   = 12

[platform.macos]
font_family = SF Mono
font_size   = 14
keybind.copy = <Meta>c

[platform.linux]
keybind.copy = <Control><Shift>c
```

`<name>` is `linux` or `macos`, the two platforms sketerm targets.
The test is a compile-time one (`builtin.os.tag`), not a runtime
probe, so a `sketerm-mux` built for macOS reads a config as macOS
even if the file was written on a Linux box. An unrecognised name
(`windows`, a typo) warns and never applies -- the same policy
unknown keys and unknown sections already have -- but the section is
still kept and its keys are still checked, so a future platform name
is not silently deleted from your file the next time you save.

### Where in the parse it applies

**Inline, in file order.** A platform section is a conditional splice
of the *top level*: while it is open, every line is handled exactly as
if it had been written at the top level, and when the platform does
not match, the line is parsed for errors and then dropped.

Three things follow.

- **Everything the top level accepts is accepted here**: profile-level
  keys (they edit the Default profile, as at the top level), app-level
  keys, and the prefix-keyed families. `keybind.<action>` inside a
  platform section appends to the same list as at the top level -- a
  later line for the same action replaces the earlier one -- and
  `symbol_map.<name>` / `shader_param.<name>` / `hint.<name>.<field>`
  behave identically.
- **A platform section cannot target a named profile.** It writes the
  top level, so it edits the Default bundle. To give a *profile* a
  per-platform value, put the platform section **before** the
  `[profile.<name>]` section and let the ordinary seeding rule carry
  it in.
- **Order matters, exactly as it already does for global keys.** A
  profile is seeded from the Default settings *as parsed so far*. So:

  ```
  font_size = 10
  [platform.linux]
  font_size = 20
  [profile.dev]        # seeded with 20 on Linux
  ```

  and the other order:

  ```
  font_size = 10
  [profile.dev]        # seeded with 10 everywhere
  [platform.linux]
  font_size = 20       # Default becomes 20; `dev` stays 10
  ```

  The serialiser always writes platform sections *before* the profile
  sections, so a file it produced reloads to the same thing.

### Keys for the other platform are still checked

A `[platform.macos]` section is parsed on Linux too -- against a
throwaway config that is then discarded. A misspelled key or an
unparseable value in it warns at load with the same message it would
get at the top level. The alternative (skip the section entirely)
means half your file is never checked and breaks the day you switch
machines.

### What a Preferences save does to it

Read this before mixing platform sections with the Preferences
dialog.

- **Your platform sections survive verbatim.** They are written back
  with their lines unchanged, before the `[profile.*]` sections.
- **But this platform's overrides also end up at the top level.** The
  section is applied inline at parse time, so nothing downstream can
  tell `font_size = 14` in `[platform.macos]` apart from
  `font_size = 14` written at the top level. The dialog serialises the
  effective value, so after a save on macOS the top level carries 14
  and the original top-level 12 is gone. On macOS nothing changes
  (the section sets 14 anyway); on **Linux** that key now starts from
  14 rather than 12, unless `[platform.linux]` sets it too.
- Consequence: **either give every key you override a value in both
  platform sections, or do not save from the dialog** on a config that
  uses them. The dialog already rewrites a hand-written file (comments
  and ordering are lost); this is the one case where it can also
  change what the file *means* on the other machine.
- `Config.save` prints a warning to stderr whenever it writes a config
  that has platform sections.

## `[domain.<name>]` -- named mux endpoints

Each section names a remote `sketerm-mux` endpoint. The command
palette gains a "New Tab on `<name>`" entry, and `sketerm mux <name>`
/ `sketerm ssh <name>` resolve the name.

| Key | Type | Default | Values |
| --- | --- | --- | --- |
| `host` | string | unset | `host` or `user@host`. Empty means the section is ignored. |
| `transport` | enum | `auto` | `auto` probes roaming UDP and falls back to the SSH pipe; `ssh` and `udp` force one. |

```
[domain.devbox]
host = skerit@192.168.1.2
transport = udp
```

## `[lsp.<name>]` -- language servers

A section whose name matches a built-in (`zls`, `clangd`,
`rust-analyzer`) **replaces it wholesale**, but the record is seeded
from the built-in at parse time. So a section carrying only
`enabled = false` still knows the command it is switching off, and
one carrying only `args` keeps the built-in's languages and root
markers. A server you never write a section for keeps following the
built-in as it evolves.

| Key | Type | Notes |
| --- | --- | --- |
| `command` | path | Executable, looked up on `PATH`. Empty disables the entry. |
| `args` | string | Whitespace-separated argv tail. |
| `languages` | string | Comma-separated LSP languageIds this server handles. |
| `root_files` | string | Comma-separated marker filenames; the nearest ancestor containing one becomes the workspace root. Empty = the document's own directory. |
| `init_options` | string | Raw JSON object passed as `initialize.initializationOptions`. Malformed JSON is dropped rather than corrupting the request. |
| `enabled` | bool | |

Note that when the prefs dialog writes the file back, every field of
an LSP section is written out rather than diffed against the
built-in: a section that silently inherited half its fields from a
built-in that later changed would quietly change behaviour on
upgrade. See `docs/lsp.md` for the client itself.

## `[mcp.<name>]` -- named MCP tool-exposure policies

A reusable tool subset for `sketerm mcp --profile <name>`, so several
assistants can share one machine with different reach. The section
namespace is `mcp.`, not `profile.`: `[profile.<name>]` is a pane
settings bundle and the two have nothing in common.

| Key | Type | Notes |
| --- | --- | --- |
| `tools` | string | Tool-exposure spec. Grammar and group names in `docs/mcp.md`. Empty = every tool. |

```
[mcp.wayland]
tools = app, files:ro

[mcp.safe]
tools = -run_command, -file_delete_tree
```

The spec is NOT validated at config-parse time -- `src/config.zig` is
compiled into `sketerm-mux` and must not depend on the MCP tool table.
`sketerm mcp --profile <name>` validates it at startup and refuses to
start on an unknown term, naming it.

---

## Precedence

1. Built-in defaults (the field initialisers in `src/config.zig`).
2. The config file, in file order -- a later line for the same key
   wins. A `[platform.<name>]` line counts as a line at the position
   it appears in the file, so a matching platform section beats an
   earlier top-level line and loses to a later one.
3. Environment overrides, which beat the file because an explicit
   invocation beats persistent config. They apply to the **Default
   profile only**; named profiles keep their own values.

| Variable | Overrides |
| --- | --- |
| `SKETERM_FONT` | `font` (absolute path to a .ttf/.otf) |
| `SKETERM_SCROLLBACK` | `scrollback` |

## Reload semantics

- **`config_auto_reload = true` (the default)** watches the config
  file and applies changes as soon as they land. The watcher handles
  editors that save by writing a temp file and renaming over the
  target, not just in-place writes, by re-arming on
  DELETED/RENAMED/MOVED_OUT. Events are debounced (200 ms), and an
  event whose file content hashes the same as the last apply is
  dropped, so the app's own writes do not loop.
- **An automatic reload never persists the config.** Neither does the
  `reload_config` action or `SIGUSR1`. The serialiser writes only
  non-default keys, so writing back would destroy a hand-written
  file's comments and ordering. Only the Preferences dialog persists.
- **`reload_config` and `SIGUSR1` work regardless of the auto-reload
  setting.** Bind the action (it has no default accelerator) or send
  the signal:

  ```
  keybind.reload_config = <Control><Shift>F5
  kill -USR1 $(pidof sketerm)
  ```

- **A reload honours an active `--config <path>` override**, re-reading
  the same file the process was started with rather than the XDG path.
- A reload that cannot read the file leaves the running config alone
  and warns -- unlike startup, where a missing file means "use
  defaults". An empty file is likewise refused, since it is nearly
  always a truncate caught mid-write.
- Auto-reload is suppressed while the Preferences dialog is open, so a
  hand edit cannot be silently undone by the dialog's own copy.

## What the Preferences dialog writes

The dialog persists to the same file, atomically (write to `.tmp`,
rename). It emits **only keys whose value differs from the default**,
so the file stays minimal; profile sections diff against the Default
settings, matching the parse-time seed, so the round-trip is exact.
Editing the file by hand and using the dialog therefore mix, but a
dialog save rewrites the file and loses hand-written comments.

Two states are not expressible in the format and so survive a
round-trip as the seeded value rather than as "unset": clearing a
profile's `palette` back to none, and clearing a `light.` / `dark.`
field back to inherit.

A third, bigger one: a config using `[platform.<name>]` sections
keeps them verbatim but has this platform's overrides flattened into
the top level. See that section for what that costs and how to avoid
it.

The list-shaped families do not have that problem: removing every
`symbol_map.<name>` or every `hint.<name>.*` entry writes no line for
them and reloads as an empty list. One related detail: a symbol map
whose family is empty routes nothing and is **not written** -- with an
empty family the line would end in a trailing space, which the parser
rejects on the next load. The Preferences dialog flags such an entry
instead of saving it.

## See also

- `data/sample.conf` -- a commented file to copy to
  `~/.config/sketerm/config.conf`.
- `docs/lsp.md` -- the language-server client.
- `docs/layout.md` -- layout files, which are separate from this
  config.
