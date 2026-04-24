# Configuration

User-level config via `$XDG_CONFIG_HOME/sketerm/config.zon`.
Load at startup only in v1; hot reload is post-v1.

## Resolution

1. `--config <path>` CLI flag — highest priority; error if missing.
2. `$XDG_CONFIG_HOME/sketerm/config.zon` — default location.
3. `$HOME/.config/sketerm/config.zon` — fallback if XDG unset.
4. No file present → baked-in defaults, no error.

`--no-config` flag bypasses file resolution entirely.

## Format

Zig Object Notation (ZON). Schema-versioned via a root `version`
field.

```zig
.{
    .version = 1,

    .font = .{
        .face = "Fira Code",
        .size = 12,
        .hinting = .slight,        // .none | .slight | .medium | .full
        .antialias = .grayscale,   // .none | .grayscale | .lcd_rgb | .lcd_bgr
    },

    .colors = .{
        .default_fg = .{ 0xEB, 0xEB, 0xEB },
        .default_bg = .{ 0x1E, 0x1E, 0x1E },
        .cursor     = .{ 0xEB, 0xEB, 0xEB },
        .palette = .{
            .{ 0x1E, 0x1E, 0x1E }, .{ 0xCC, 0x00, 0x00 },
            .{ 0x4E, 0x9A, 0x06 }, .{ 0xC4, 0xA0, 0x00 },
            .{ 0x34, 0x65, 0xA4 }, .{ 0x75, 0x50, 0x7B },
            .{ 0x06, 0x98, 0x9A }, .{ 0xD3, 0xD7, 0xCF },
            .{ 0x55, 0x57, 0x53 }, .{ 0xEF, 0x29, 0x29 },
            .{ 0x8A, 0xE2, 0x34 }, .{ 0xFC, 0xE9, 0x4F },
            .{ 0x72, 0x9F, 0xCF }, .{ 0xAD, 0x7F, 0xA8 },
            .{ 0x34, 0xE2, 0xE2 }, .{ 0xEE, 0xEE, 0xEC },
        },
    },

    .cursor = .{
        .shape = .block,       // .block | .underline | .bar
        .blink = true,
    },

    .scrollback = .{
        .lines = 10_000,
    },

    .mouse = .{
        .click_focus = true,
        .hide_on_type = false,
        .middle_click_paste = true,   // primary selection paste
    },

    .clipboard = .{
        .osc52_read = .prompt,         // .prompt | .allow | .deny
        .osc52_max_bytes = 1_048_576,
        .bracketed_paste = true,
    },

    .input = .{
        .modify_other_keys = 1,        // 0 = disable, 1 = v1 default
    },

    .term = .{
        .value = .auto,                // .auto = sketerm-256color
                                       //   with fallback probe
                                       // .force_xterm = always
                                       //   xterm-256color
    },

    .layout = .{
        .auto_save = true,             // write last.zon on clean exit
    },

    .images = .{
        .max_per_pane_bytes = 256 * 1024 * 1024,
        .max_per_image_bytes = 64 * 1024 * 1024,
        .max_per_window_bytes = 1024 * 1024 * 1024,
    },

    .hold_on_exit = true,

    .bell = .{
        .urgency_hint = true,
        .audible = false,
    },

    .keybindings = &.{
        .{ .keys = "<Ctrl><Shift>c",     .action = .copy },
        .{ .keys = "<Ctrl><Shift>v",     .action = .paste },
        .{ .keys = "<Ctrl><Shift>t",     .action = .new_tab },
        .{ .keys = "<Ctrl><Shift>w",     .action = .close_tab },
        .{ .keys = "<Ctrl><Shift>d",     .action = .split_horizontal },
        .{ .keys = "<Ctrl><Shift>r",     .action = .split_vertical },
        .{ .keys = "<Ctrl>Tab",          .action = .next_pane },
        .{ .keys = "<Ctrl><Shift>Tab",   .action = .prev_pane },
        .{ .keys = "<Ctrl><Shift>plus",  .action = .increase_font },
        .{ .keys = "<Ctrl><Shift>minus", .action = .decrease_font },
        .{ .keys = "<Ctrl><Shift>0",     .action = .reset_font },
    },
}
```

## Defaults philosophy

Every field has a baked-in default in `src/config.zig`
(`Config.default()`). Config overlays — any missing field keeps
its default. Missing file → all defaults.

## Schema versioning

`version: u32 = 1`. Policy:

- Equal → load directly.
- Lower → run ordered migrations (documented in
  `docs/MIGRATIONS.md` once we first bump).
- Higher → error — *"config requires sketerm ≥ vX; upgrade"*.

Additive optional fields with safe defaults do not require a bump.

## Keybinding model

### Actions (fixed enum, v1)

```
copy, paste, paste_primary, select_all, clear_scrollback,
new_tab, close_tab, rename_tab,
next_tab, prev_tab, tab_1 … tab_9,
split_horizontal, split_vertical,
close_pane, next_pane, prev_pane,
increase_font, decrease_font, reset_font,
scroll_up_line, scroll_down_line,
scroll_up_page, scroll_down_page,
scroll_to_top, scroll_to_bottom,
reset_terminal, toggle_fullscreen,
none,                    // explicitly unbind a default
```

Plugin-extensible post-v1.

### Key format

Standard GTK accelerator syntax — same as `gtk_accelerator_parse`:

- `<Ctrl>`, `<Shift>`, `<Alt>`, `<Meta>`, `<Super>` prefixes
- Named keys: `Tab`, `Return`, `Escape`, `F1`–`F20`, `Page_Up`,
  `Home`, `End`, `plus`, `minus`, ...
- Printable keys: lowercase letter for the key cap (`c`, `v`, ...).

Matched at runtime via `gtk_accelerator_match`.

### Conflict resolution

- Config entry overrides default (same keys → user wins).
- Duplicate keys within config → last-wins, warning on load.
- Unknown action → warn on load, entry skipped.
- Unparseable keys → warn on load, entry skipped.

### Unbinding a default

```zig
.{ .keys = "<Ctrl><Shift>c", .action = .none },
```

Removes default binding without replacing.

## Font

```zig
.font = .{
    .face = "Fira Code",     // Pango face descriptor
    .size = 12,
    .size_adjust = 0,        // pixel offset applied after raster
    .hinting = .slight,      // .none | .slight | .medium | .full
    .antialias = .grayscale, // .none | .grayscale | .lcd_rgb | .lcd_bgr
},
```

Face resolution via `pango_font_description_from_string` (wraps
`fontconfig`).

**Hinting modes** map to FreeType load flags:
- `none` → `FT_LOAD_NO_HINTING`
- `slight` → `FT_LOAD_TARGET_LIGHT` (default; matches most distros)
- `medium` → `FT_LOAD_TARGET_NORMAL`
- `full` → `FT_LOAD_FORCE_AUTOHINT` + `FT_LOAD_TARGET_NORMAL`

**Antialias modes**:
- `none` → `FT_LOAD_TARGET_MONO` (1-bit bitmap, aliased)
- `grayscale` → 8-bit alpha atlas (default; our atlas is R8)
- `lcd_rgb` / `lcd_bgr` → `FT_LOAD_TARGET_LCD` / LCD_V with RGBA
  atlas; requires shader-side gamma-correct subpixel blend. Post-v1
  (shader adds ~30 lines, correct subpixel is easy to get wrong).

**v1 limitations**:
- Single face, no fallback chain. Missing glyphs render as tofu
  (⬜). Font fallback lands in M10.
- LCD subpixel modes accepted in config but silently fall back to
  grayscale in v1.

## Colors

- `palette`: 16 entries (ANSI 0..15), each `[3]u8` RGB.
- 256-color mode extends with a baked-in xterm 6×6×6 + grayscale
  ramp; not configurable in v1.
- Truecolor (`38;2;r;g;b`) always passes through unchanged.
- `default_fg`, `default_bg`, `cursor`: each `[3]u8` RGB.

## Error handling

Parse errors are warnings, not fatal:

- Single field invalid → warn; that field uses default.
- Whole file unparseable → warn; all defaults.
- All warnings → stderr + scratch log viewable via menu
  *Help / Config diagnostics*.

Never silently apply a partially-broken config without saying so.

## File-size cap

Config file > 1 MB → reject with diagnostic. Legitimate configs
are ~few KB; anything larger is a red flag.

## Future extensions (post-v1, non-binding)

- Hot reload via GIO file monitor.
- Multiple profiles with per-profile overrides.
- Per-pane overrides at layout level.
- Environment-conditional overrides (dark/light based on time).
- Import converters from Alacritty / Kitty / iTerm2 formats.
- User-defined actions via Lua plugin hooks.
