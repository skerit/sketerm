//! Hand-written interface tables for the protocols the sketerm
//! compositor advertises: core wayland + xdg-shell + the modern
//! client staples (selections incl. primary, relative pointer +
//! constraints, text-input v3, xdg-activation, presentation-time,
//! idle-inhibit, pointer gestures). Buffers are shm plus an opt-in
//! linux-dmabuf path (SKETERM_MUX_DMABUF), v3 or v4 depending on
//! whether a main DRM device resolved; advertised format and
//! modifier capabilities are selected by the daemon's importer.
//!
//! Signature letters match wire.zig's ArgIter:
//!   i int · u uint · f fixed · s string · o object · n new_id ·
//!   a array · h fd · ? nullable (next arg may be null/0)
//!
//! Versions/sigs transcribed from wayland.xml (1.23) and
//! xdg-shell.xml (stable). `since` is the interface version that
//! introduced the message; messages are indexed by opcode order.

const std = @import("std");
const wire = @import("wire.zig");
const dmabuf = @import("dmabuf.zig");

pub const Message = struct {
    name: []const u8,
    sig: []const u8,
    since: u32 = 1,
    /// Interface created by an 'n' arg. Null for wl_registry.bind,
    /// whose target interface is named inline on the wire.
    new_id_iface: ?*const Interface = null,
};

pub const Interface = struct {
    name: []const u8,
    /// Highest version these tables describe (and the max the
    /// compositor may advertise).
    version: u32,
    requests: []const Message = &.{},
    events: []const Message = &.{},
};

/// File descriptors a message carries (paired with SCM_RIGHTS data
/// in arrival order).
pub fn fdCount(sig: []const u8) u32 {
    var n: u32 = 0;
    for (sig) |ch| {
        if (ch == 'h') n += 1;
    }
    return n;
}

/// The 'n' arg's position is needed to learn a new object's id when
/// relaying: null when the message creates nothing.
pub fn newIdArg(msg: *const Message) ?usize {
    var idx: usize = 0;
    for (msg.sig) |ch| {
        switch (ch) {
            'n' => return idx,
            '?' => {},
            else => idx += 1,
        }
    }
    return null;
}

pub fn find(name: []const u8) ?*const Interface {
    for (all) |iface| {
        if (std.mem.eql(u8, iface.name, name)) return iface;
    }
    return null;
}

// ─── core wayland ───────────────────────────────────────────────

pub const wl_display = Interface{
    .name = "wl_display",
    .version = 1,
    .requests = &.{
        .{ .name = "sync", .sig = "n", .new_id_iface = &wl_callback },
        .{ .name = "get_registry", .sig = "n", .new_id_iface = &wl_registry },
    },
    .events = &.{
        .{ .name = "error", .sig = "ous" },
        .{ .name = "delete_id", .sig = "u" },
    },
};

pub const wl_registry = Interface{
    .name = "wl_registry",
    .version = 1,
    .requests = &.{
        // wayland.xml says bind(name: uint, id: new_id) with no
        // interface — the untyped new_id expands on the wire to
        // (interface: string, version: uint, id: new_id).
        .{ .name = "bind", .sig = "usun" },
    },
    .events = &.{
        .{ .name = "global", .sig = "usu" },
        .{ .name = "global_remove", .sig = "u" },
    },
};

pub const wl_callback = Interface{
    .name = "wl_callback",
    .version = 1,
    .events = &.{
        .{ .name = "done", .sig = "u" },
    },
};

// wl_compositor/wl_surface pin v6: wayland 1.25's v7 additions
// (compositor.release, surface.get_release) are excluded — apps
// bound at <=6 can never legally send them.
pub const wl_compositor = Interface{
    .name = "wl_compositor",
    .version = 7,
    .requests = &.{
        .{ .name = "create_surface", .sig = "n", .new_id_iface = &wl_surface },
        .{ .name = "create_region", .sig = "n", .new_id_iface = &wl_region },
        .{ .name = "release", .sig = "", .since = 7 },
    },
};

pub const wl_subcompositor = Interface{
    .name = "wl_subcompositor",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "get_subsurface", .sig = "noo", .new_id_iface = &wl_subsurface },
    },
};

pub const wl_subsurface = Interface{
    .name = "wl_subsurface",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "set_position", .sig = "ii" },
        .{ .name = "place_above", .sig = "o" },
        .{ .name = "place_below", .sig = "o" },
        .{ .name = "set_sync", .sig = "" },
        .{ .name = "set_desync", .sig = "" },
    },
};

pub const wl_shm = Interface{
    .name = "wl_shm",
    .version = 2,
    .requests = &.{
        .{ .name = "create_pool", .sig = "nhi", .new_id_iface = &wl_shm_pool },
        .{ .name = "release", .sig = "", .since = 2 },
    },
    .events = &.{
        .{ .name = "format", .sig = "u" },
    },
};

pub const wl_shm_pool = Interface{
    .name = "wl_shm_pool",
    .version = 2,
    .requests = &.{
        .{ .name = "create_buffer", .sig = "niiiiu", .new_id_iface = &wl_buffer },
        .{ .name = "destroy", .sig = "" },
        .{ .name = "resize", .sig = "i" },
    },
};

pub const wl_buffer = Interface{
    .name = "wl_buffer",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "release", .sig = "" },
    },
};

/// linux-dmabuf up to v4. Import policy follows the daemon's
/// advertised format/modifier capabilities; v4 is announced only when
/// the daemon resolved a main DRM device (Compositor.dmabuf_main_device),
/// since the feedback events are meaningless without one.
pub const zwp_linux_dmabuf_v1 = Interface{
    .name = "zwp_linux_dmabuf_v1",
    .version = 4,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "create_params", .sig = "n", .new_id_iface = &zwp_linux_buffer_params_v1 },
        .{ .name = "get_default_feedback", .sig = "n", .since = 4, .new_id_iface = &zwp_linux_dmabuf_feedback_v1 },
        .{ .name = "get_surface_feedback", .sig = "no", .since = 4, .new_id_iface = &zwp_linux_dmabuf_feedback_v1 },
    },
    .events = &.{
        // Deprecated at v4: feedback replaces them and the spec
        // forbids sending either to a v4 client.
        .{ .name = "format", .sig = "u" },
        .{ .name = "modifier", .sig = "uuu", .since = 3 },
    },
};

/// Per-client (or per-surface) format advertisement. `format_table`
/// carries an fd, so the daemon materializes it from the brain's
/// `dmabuf_feedback` pipe unit — the same trick as wl_keyboard.keymap.
pub const zwp_linux_dmabuf_feedback_v1 = Interface{
    .name = "zwp_linux_dmabuf_feedback_v1",
    .version = 4,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "done", .sig = "" },
        .{ .name = "format_table", .sig = "hu" },
        .{ .name = "main_device", .sig = "a" },
        .{ .name = "tranche_done", .sig = "" },
        .{ .name = "tranche_target_device", .sig = "a" },
        .{ .name = "tranche_formats", .sig = "a" },
        .{ .name = "tranche_flags", .sig = "u" },
    },
};

pub const zwp_linux_buffer_params_v1 = Interface{
    .name = "zwp_linux_buffer_params_v1",
    .version = 3,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "add", .sig = "huuuuu" },
        .{ .name = "create", .sig = "iiuu" },
        .{ .name = "create_immed", .sig = "niiuu", .since = 2, .new_id_iface = &wl_buffer },
    },
    .events = &.{
        .{ .name = "created", .sig = "n", .new_id_iface = &wl_buffer },
        .{ .name = "failed", .sig = "" },
    },
};

/// DRM metadata shared with the importer and tracker.
pub const DRM_FORMAT_ARGB8888 = dmabuf.DRM_FORMAT_ARGB8888;
pub const DRM_FORMAT_XRGB8888 = dmabuf.DRM_FORMAT_XRGB8888;
pub const DRM_FORMAT_MOD_LINEAR = dmabuf.DRM_FORMAT_MOD_LINEAR;
pub const DRM_FORMAT_MOD_INVALID = dmabuf.DRM_FORMAT_MOD_INVALID;

pub const wl_surface = Interface{
    .name = "wl_surface",
    .version = 7,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "attach", .sig = "?oii" },
        .{ .name = "damage", .sig = "iiii" },
        .{ .name = "frame", .sig = "n", .new_id_iface = &wl_callback },
        .{ .name = "set_opaque_region", .sig = "?o" },
        .{ .name = "set_input_region", .sig = "?o" },
        .{ .name = "commit", .sig = "" },
        .{ .name = "set_buffer_transform", .sig = "i", .since = 2 },
        .{ .name = "set_buffer_scale", .sig = "i", .since = 3 },
        .{ .name = "damage_buffer", .sig = "iiii", .since = 4 },
        .{ .name = "offset", .sig = "ii", .since = 5 },
        .{ .name = "get_release", .sig = "n", .since = 7, .new_id_iface = &wl_callback },
    },
    .events = &.{
        .{ .name = "enter", .sig = "o" },
        .{ .name = "leave", .sig = "o" },
        .{ .name = "preferred_buffer_scale", .sig = "i", .since = 6 },
        .{ .name = "preferred_buffer_transform", .sig = "u", .since = 6 },
    },
};

/// The registry-leak fix: without it a client that creates and drops
/// registries (GTK does, per display re-probe) leaks a server object
/// each time, because wl_registry has no destructor of its own.
pub const wl_fixes = Interface{
    .name = "wl_fixes",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "destroy_registry", .sig = "o" },
    },
};

pub const wl_region = Interface{
    .name = "wl_region",
    .version = 7,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "add", .sig = "iiii" },
        .{ .name = "subtract", .sig = "iiii" },
    },
};

pub const wl_seat = Interface{
    .name = "wl_seat",
    .version = 10,
    .requests = &.{
        .{ .name = "get_pointer", .sig = "n", .new_id_iface = &wl_pointer },
        .{ .name = "get_keyboard", .sig = "n", .new_id_iface = &wl_keyboard },
        .{ .name = "get_touch", .sig = "n", .new_id_iface = &wl_touch },
        .{ .name = "release", .sig = "", .since = 5 },
    },
    .events = &.{
        .{ .name = "capabilities", .sig = "u" },
        .{ .name = "name", .sig = "s", .since = 2 },
    },
};

pub const wl_pointer = Interface{
    .name = "wl_pointer",
    .version = 10,
    .requests = &.{
        .{ .name = "set_cursor", .sig = "u?oii" },
        .{ .name = "release", .sig = "", .since = 3 },
    },
    .events = &.{
        .{ .name = "enter", .sig = "uoff" },
        .{ .name = "leave", .sig = "uo" },
        .{ .name = "motion", .sig = "uff" },
        .{ .name = "button", .sig = "uuuu" },
        .{ .name = "axis", .sig = "uuf" },
        .{ .name = "frame", .sig = "", .since = 5 },
        .{ .name = "axis_source", .sig = "u", .since = 5 },
        .{ .name = "axis_stop", .sig = "uu", .since = 5 },
        .{ .name = "axis_discrete", .sig = "ui", .since = 5 },
        .{ .name = "axis_value120", .sig = "ui", .since = 8 },
        .{ .name = "axis_relative_direction", .sig = "uu", .since = 9 },
    },
};

pub const wl_keyboard = Interface{
    .name = "wl_keyboard",
    .version = 10,
    .requests = &.{
        .{ .name = "release", .sig = "", .since = 3 },
    },
    .events = &.{
        .{ .name = "keymap", .sig = "uhu" },
        .{ .name = "enter", .sig = "uoa" },
        .{ .name = "leave", .sig = "uo" },
        .{ .name = "key", .sig = "uuuu" },
        .{ .name = "modifiers", .sig = "uuuuu" },
        .{ .name = "repeat_info", .sig = "ii", .since = 4 },
    },
};

pub const wl_touch = Interface{
    .name = "wl_touch",
    .version = 10,
    .requests = &.{
        .{ .name = "release", .sig = "", .since = 3 },
    },
    .events = &.{
        .{ .name = "down", .sig = "uuoiff" },
        .{ .name = "up", .sig = "uui" },
        .{ .name = "motion", .sig = "uiff" },
        .{ .name = "frame", .sig = "" },
        .{ .name = "cancel", .sig = "" },
        .{ .name = "shape", .sig = "iff", .since = 6 },
        .{ .name = "orientation", .sig = "if", .since = 6 },
    },
};

pub const wl_output = Interface{
    .name = "wl_output",
    .version = 4,
    .requests = &.{
        .{ .name = "release", .sig = "", .since = 3 },
    },
    .events = &.{
        .{ .name = "geometry", .sig = "iiiiissi" },
        .{ .name = "mode", .sig = "uiii" },
        .{ .name = "done", .sig = "", .since = 2 },
        .{ .name = "scale", .sig = "i", .since = 2 },
        .{ .name = "name", .sig = "s", .since = 4 },
        .{ .name = "description", .sig = "s", .since = 4 },
    },
};

/// xdg-output: augments wl_output with LOGICAL geometry. SDL/Vulkan
/// clients probe for it and change behavior when absent.
pub const zxdg_output_manager_v1 = Interface{
    .name = "zxdg_output_manager_v1",
    .version = 3,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "get_xdg_output", .sig = "no", .new_id_iface = &zxdg_output_v1 },
    },
    .events = &.{},
};

pub const zxdg_output_v1 = Interface{
    .name = "zxdg_output_v1",
    .version = 3,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "logical_position", .sig = "ii" },
        .{ .name = "logical_size", .sig = "ii" },
        .{ .name = "done", .sig = "" },
        .{ .name = "name", .sig = "s", .since = 2 },
        .{ .name = "description", .sig = "s", .since = 2 },
    },
};

// ─── data device (clipboard / dnd) ──────────────────────────────

pub const wl_data_offer = Interface{
    .name = "wl_data_offer",
    .version = 4,
    .requests = &.{
        .{ .name = "accept", .sig = "u?s" },
        .{ .name = "receive", .sig = "sh" },
        .{ .name = "destroy", .sig = "" },
        .{ .name = "finish", .sig = "", .since = 3 },
        .{ .name = "set_actions", .sig = "uu", .since = 3 },
    },
    .events = &.{
        .{ .name = "offer", .sig = "s" },
        .{ .name = "source_actions", .sig = "u", .since = 3 },
        .{ .name = "action", .sig = "u", .since = 3 },
    },
};

pub const wl_data_source = Interface{
    .name = "wl_data_source",
    .version = 4,
    .requests = &.{
        .{ .name = "offer", .sig = "s" },
        .{ .name = "destroy", .sig = "" },
        .{ .name = "set_actions", .sig = "u", .since = 3 },
    },
    .events = &.{
        .{ .name = "target", .sig = "?s" },
        .{ .name = "send", .sig = "sh" },
        .{ .name = "cancelled", .sig = "" },
        .{ .name = "dnd_drop_performed", .sig = "", .since = 3 },
        .{ .name = "dnd_finished", .sig = "", .since = 3 },
        .{ .name = "action", .sig = "u", .since = 3 },
    },
};

pub const wl_data_device = Interface{
    .name = "wl_data_device",
    .version = 4,
    .requests = &.{
        .{ .name = "start_drag", .sig = "?oo?ou" },
        .{ .name = "set_selection", .sig = "?ou" },
        .{ .name = "release", .sig = "", .since = 2 },
    },
    .events = &.{
        // The ONE server-created object in our scope — both the
        // daemon tracker and clients register it from this event.
        .{ .name = "data_offer", .sig = "n", .new_id_iface = &wl_data_offer },
        .{ .name = "enter", .sig = "uoff?o" },
        .{ .name = "leave", .sig = "" },
        .{ .name = "motion", .sig = "uff" },
        .{ .name = "drop", .sig = "" },
        .{ .name = "selection", .sig = "?o" },
    },
};

pub const wl_data_device_manager = Interface{
    .name = "wl_data_device_manager",
    .version = 4,
    .requests = &.{
        .{ .name = "create_data_source", .sig = "n", .new_id_iface = &wl_data_source },
        .{ .name = "get_data_device", .sig = "no", .new_id_iface = &wl_data_device },
        .{ .name = "release", .sig = "", .since = 4 },
    },
};

// ─── wlr-data-control (surface-less clipboard) ──────────────────
//
// The headless clipboard path: a client sets/reads the selection
// WITHOUT owning a surface or holding keyboard focus, so tools like
// wl-copy/wl-paste don't flash a throwaway toplevel (taskbar entry)
// just to grab focus. We advertise v1 (selection only; no primary
// selection, which is the v2 addition). Mirrors the wl_data_*
// family, with different opcodes for `selection`/`send`/`receive`.

pub const zwlr_data_control_offer_v1 = Interface{
    .name = "zwlr_data_control_offer_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "receive", .sig = "sh" },
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "offer", .sig = "s" },
    },
};

pub const zwlr_data_control_source_v1 = Interface{
    .name = "zwlr_data_control_source_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "offer", .sig = "s" },
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "send", .sig = "sh" },
        .{ .name = "cancelled", .sig = "" },
    },
};

pub const zwlr_data_control_device_v1 = Interface{
    .name = "zwlr_data_control_device_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "set_selection", .sig = "?o" },
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        // Server-created offer object; tracker + client register it
        // from this event (like wl_data_device.data_offer).
        .{ .name = "data_offer", .sig = "n", .new_id_iface = &zwlr_data_control_offer_v1 },
        .{ .name = "selection", .sig = "?o" },
        .{ .name = "finished", .sig = "" },
    },
};

pub const zwlr_data_control_manager_v1 = Interface{
    .name = "zwlr_data_control_manager_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "create_data_source", .sig = "n", .new_id_iface = &zwlr_data_control_source_v1 },
        .{ .name = "get_data_device", .sig = "no", .new_id_iface = &zwlr_data_control_device_v1 },
        .{ .name = "destroy", .sig = "" },
    },
};

// ─── modern niceties (cursor-shape / viewporter / fractional) ───

pub const wp_cursor_shape_manager_v1 = Interface{
    .name = "wp_cursor_shape_manager_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "get_pointer", .sig = "no", .new_id_iface = &wp_cursor_shape_device_v1 },
        .{ .name = "get_tablet_tool_v2", .sig = "no", .new_id_iface = &wp_cursor_shape_device_v1 },
    },
};

pub const wp_cursor_shape_device_v1 = Interface{
    .name = "wp_cursor_shape_device_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "set_shape", .sig = "uu" },
    },
};

pub const wp_viewporter = Interface{
    .name = "wp_viewporter",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "get_viewport", .sig = "no", .new_id_iface = &wp_viewport },
    },
};

pub const wp_viewport = Interface{
    .name = "wp_viewport",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "set_source", .sig = "ffff" },
        .{ .name = "set_destination", .sig = "ii" },
    },
};

pub const wp_fractional_scale_manager_v1 = Interface{
    .name = "wp_fractional_scale_manager_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "get_fractional_scale", .sig = "no", .new_id_iface = &wp_fractional_scale_v1 },
    },
};

pub const wp_fractional_scale_v1 = Interface{
    .name = "wp_fractional_scale_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "preferred_scale", .sig = "u" },
    },
};

pub const zxdg_decoration_manager_v1 = Interface{
    .name = "zxdg_decoration_manager_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "get_toplevel_decoration", .sig = "no", .new_id_iface = &zxdg_toplevel_decoration_v1 },
    },
};

pub const zxdg_toplevel_decoration_v1 = Interface{
    .name = "zxdg_toplevel_decoration_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "set_mode", .sig = "u" },
        .{ .name = "unset_mode", .sig = "" },
    },
    .events = &.{
        .{ .name = "configure", .sig = "u" },
    },
};

// ─── xdg-foreign v2 ─────────────────────────────────────────────
// Cross-client window parenting: a client exports its toplevel and
// hands the opaque handle to another process (over D-Bus), which
// imports it and parents a dialog to it. GTK4's portal
// `parent_window` path is the motivating consumer. Only v2 is
// advertised — see the note on the globals table in compositor.zig.
// Transcribed from unstable/xdg-foreign/xdg-foreign-unstable-v2.xml;
// every interface there is at version 1.

pub const zxdg_exporter_v2 = Interface{
    .name = "zxdg_exporter_v2",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "export_toplevel", .sig = "no", .new_id_iface = &zxdg_exported_v2 },
    },
};

pub const zxdg_importer_v2 = Interface{
    .name = "zxdg_importer_v2",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "import_toplevel", .sig = "ns", .new_id_iface = &zxdg_imported_v2 },
    },
};

pub const zxdg_exported_v2 = Interface{
    .name = "zxdg_exported_v2",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "handle", .sig = "s" },
    },
};

pub const zxdg_imported_v2 = Interface{
    .name = "zxdg_imported_v2",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "set_parent_of", .sig = "o" },
    },
    .events = &.{
        .{ .name = "destroyed", .sig = "" },
    },
};

// ─── xdg-dialog v1 ──────────────────────────────────────────────
// The ONLY way an xdg-shell client can say "this toplevel is modal
// over its parent" — xdg_toplevel has no modality request at all.
// GTK4 (>= 4.14) binds it and calls set_modal for every
// gtk_window_set_modal dialog, which is what makes a forwarded
// app's file dialog block its own window. Transcribed from
// staging/xdg-dialog/xdg-dialog-v1.xml (both interfaces v1).

pub const xdg_wm_dialog_v1 = Interface{
    .name = "xdg_wm_dialog_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "get_xdg_dialog", .sig = "no", .new_id_iface = &xdg_dialog_v1 },
    },
};

pub const xdg_dialog_v1 = Interface{
    .name = "xdg_dialog_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "set_modal", .sig = "" },
        .{ .name = "unset_modal", .sig = "" },
    },
};

// ─── primary selection (middle-click paste) ─────────────────────

pub const zwp_primary_selection_offer_v1 = Interface{
    .name = "zwp_primary_selection_offer_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "receive", .sig = "sh" },
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "offer", .sig = "s" },
    },
};

pub const zwp_primary_selection_source_v1 = Interface{
    .name = "zwp_primary_selection_source_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "offer", .sig = "s" },
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "send", .sig = "sh" },
        .{ .name = "cancelled", .sig = "" },
    },
};

pub const zwp_primary_selection_device_v1 = Interface{
    .name = "zwp_primary_selection_device_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "set_selection", .sig = "?ou" },
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        // Server-created offer object (like wl_data_device.data_offer).
        .{ .name = "data_offer", .sig = "n", .new_id_iface = &zwp_primary_selection_offer_v1 },
        .{ .name = "selection", .sig = "?o" },
    },
};

pub const zwp_primary_selection_device_manager_v1 = Interface{
    .name = "zwp_primary_selection_device_manager_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "create_source", .sig = "n", .new_id_iface = &zwp_primary_selection_source_v1 },
        .{ .name = "get_device", .sig = "no", .new_id_iface = &zwp_primary_selection_device_v1 },
        .{ .name = "destroy", .sig = "" },
    },
};

// ─── relative pointer + constraints (pointer lock) ──────────────

pub const zwp_relative_pointer_manager_v1 = Interface{
    .name = "zwp_relative_pointer_manager_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "get_relative_pointer", .sig = "no", .new_id_iface = &zwp_relative_pointer_v1 },
    },
};

pub const zwp_relative_pointer_v1 = Interface{
    .name = "zwp_relative_pointer_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "relative_motion", .sig = "uuffff" },
    },
};

pub const zwp_pointer_constraints_v1 = Interface{
    .name = "zwp_pointer_constraints_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "lock_pointer", .sig = "noo?ou", .new_id_iface = &zwp_locked_pointer_v1 },
        .{ .name = "confine_pointer", .sig = "noo?ou", .new_id_iface = &zwp_confined_pointer_v1 },
    },
};

pub const zwp_locked_pointer_v1 = Interface{
    .name = "zwp_locked_pointer_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "set_cursor_position_hint", .sig = "ff" },
        .{ .name = "set_region", .sig = "?o" },
    },
    .events = &.{
        .{ .name = "locked", .sig = "" },
        .{ .name = "unlocked", .sig = "" },
    },
};

pub const zwp_confined_pointer_v1 = Interface{
    .name = "zwp_confined_pointer_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "set_region", .sig = "?o" },
    },
    .events = &.{
        .{ .name = "confined", .sig = "" },
        .{ .name = "unconfined", .sig = "" },
    },
};

// ─── text-input v3 (IME) ────────────────────────────────────────

pub const zwp_text_input_manager_v3 = Interface{
    .name = "zwp_text_input_manager_v3",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "get_text_input", .sig = "no", .new_id_iface = &zwp_text_input_v3 },
    },
};

pub const zwp_text_input_v3 = Interface{
    .name = "zwp_text_input_v3",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "enable", .sig = "" },
        .{ .name = "disable", .sig = "" },
        .{ .name = "set_surrounding_text", .sig = "sii" },
        .{ .name = "set_text_change_cause", .sig = "u" },
        .{ .name = "set_content_type", .sig = "uu" },
        .{ .name = "set_cursor_rectangle", .sig = "iiii" },
        .{ .name = "commit", .sig = "" },
    },
    .events = &.{
        .{ .name = "enter", .sig = "o" },
        .{ .name = "leave", .sig = "o" },
        .{ .name = "preedit_string", .sig = "?sii" },
        .{ .name = "commit_string", .sig = "?s" },
        .{ .name = "delete_surrounding_text", .sig = "uu" },
        .{ .name = "done", .sig = "u" },
    },
};

// ─── xdg-activation (focus/raise tokens) ────────────────────────

pub const xdg_activation_v1 = Interface{
    .name = "xdg_activation_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "get_activation_token", .sig = "n", .new_id_iface = &xdg_activation_token_v1 },
        .{ .name = "activate", .sig = "so" },
    },
};

pub const xdg_activation_token_v1 = Interface{
    .name = "xdg_activation_token_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "set_serial", .sig = "uo" },
        .{ .name = "set_app_id", .sig = "s" },
        .{ .name = "set_surface", .sig = "o" },
        .{ .name = "commit", .sig = "" },
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "done", .sig = "s" },
    },
};

// ─── presentation-time ──────────────────────────────────────────

pub const wp_presentation = Interface{
    .name = "wp_presentation",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "feedback", .sig = "on", .new_id_iface = &wp_presentation_feedback },
    },
    .events = &.{
        .{ .name = "clock_id", .sig = "u" },
    },
};

pub const wp_presentation_feedback = Interface{
    .name = "wp_presentation_feedback",
    .version = 1,
    .events = &.{
        .{ .name = "sync_output", .sig = "o" },
        .{ .name = "presented", .sig = "uuuuuuu" },
        .{ .name = "discarded", .sig = "" },
    },
};

// ─── idle-inhibit (accepted, inert) ─────────────────────────────

pub const zwp_idle_inhibit_manager_v1 = Interface{
    .name = "zwp_idle_inhibit_manager_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "create_inhibitor", .sig = "no", .new_id_iface = &zwp_idle_inhibitor_v1 },
    },
};

pub const zwp_idle_inhibitor_v1 = Interface{
    .name = "zwp_idle_inhibitor_v1",
    .version = 1,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
    },
};

// ─── pointer gestures (accepted, inert — no gestures detected) ──

pub const zwp_pointer_gestures_v1 = Interface{
    .name = "zwp_pointer_gestures_v1",
    .version = 3,
    .requests = &.{
        .{ .name = "get_swipe_gesture", .sig = "no", .new_id_iface = &zwp_pointer_gesture_swipe_v1 },
        .{ .name = "get_pinch_gesture", .sig = "no", .new_id_iface = &zwp_pointer_gesture_pinch_v1 },
        .{ .name = "release", .sig = "", .since = 2 },
        .{ .name = "get_hold_gesture", .sig = "no", .since = 3, .new_id_iface = &zwp_pointer_gesture_hold_v1 },
    },
};

pub const zwp_pointer_gesture_swipe_v1 = Interface{
    .name = "zwp_pointer_gesture_swipe_v1",
    .version = 2,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "begin", .sig = "uuou" },
        .{ .name = "update", .sig = "uff" },
        .{ .name = "end", .sig = "uui" },
    },
};

pub const zwp_pointer_gesture_pinch_v1 = Interface{
    .name = "zwp_pointer_gesture_pinch_v1",
    .version = 2,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "begin", .sig = "uuou" },
        .{ .name = "update", .sig = "uffff" },
        .{ .name = "end", .sig = "uui" },
    },
};

pub const zwp_pointer_gesture_hold_v1 = Interface{
    .name = "zwp_pointer_gesture_hold_v1",
    .version = 3,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
    },
    .events = &.{
        .{ .name = "begin", .sig = "uuou" },
        .{ .name = "end", .sig = "uui" },
    },
};

// ─── xdg-shell ──────────────────────────────────────────────────

pub const xdg_wm_base = Interface{
    .name = "xdg_wm_base",
    .version = 6,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "create_positioner", .sig = "n", .new_id_iface = &xdg_positioner },
        .{ .name = "get_xdg_surface", .sig = "no", .new_id_iface = &xdg_surface },
        .{ .name = "pong", .sig = "u" },
    },
    .events = &.{
        .{ .name = "ping", .sig = "u" },
    },
};

pub const xdg_positioner = Interface{
    .name = "xdg_positioner",
    .version = 6,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "set_size", .sig = "ii" },
        .{ .name = "set_anchor_rect", .sig = "iiii" },
        .{ .name = "set_anchor", .sig = "u" },
        .{ .name = "set_gravity", .sig = "u" },
        .{ .name = "set_constraint_adjustment", .sig = "u" },
        .{ .name = "set_offset", .sig = "ii" },
        .{ .name = "set_reactive", .sig = "", .since = 3 },
        .{ .name = "set_parent_size", .sig = "ii", .since = 3 },
        .{ .name = "set_parent_configure", .sig = "u", .since = 3 },
    },
};

pub const xdg_surface = Interface{
    .name = "xdg_surface",
    .version = 6,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "get_toplevel", .sig = "n", .new_id_iface = &xdg_toplevel },
        .{ .name = "get_popup", .sig = "n?oo", .new_id_iface = &xdg_popup },
        .{ .name = "set_window_geometry", .sig = "iiii" },
        .{ .name = "ack_configure", .sig = "u" },
    },
    .events = &.{
        .{ .name = "configure", .sig = "u" },
    },
};

pub const xdg_toplevel = Interface{
    .name = "xdg_toplevel",
    .version = 6,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "set_parent", .sig = "?o" },
        .{ .name = "set_title", .sig = "s" },
        .{ .name = "set_app_id", .sig = "s" },
        .{ .name = "show_window_menu", .sig = "ouii" },
        .{ .name = "move", .sig = "ou" },
        .{ .name = "resize", .sig = "ouu" },
        .{ .name = "set_max_size", .sig = "ii" },
        .{ .name = "set_min_size", .sig = "ii" },
        .{ .name = "set_maximized", .sig = "" },
        .{ .name = "unset_maximized", .sig = "" },
        .{ .name = "set_fullscreen", .sig = "?o" },
        .{ .name = "unset_fullscreen", .sig = "" },
        .{ .name = "set_minimized", .sig = "" },
    },
    .events = &.{
        .{ .name = "configure", .sig = "iia" },
        .{ .name = "close", .sig = "" },
        .{ .name = "configure_bounds", .sig = "ii", .since = 4 },
        .{ .name = "wm_capabilities", .sig = "a", .since = 5 },
    },
};

pub const xdg_popup = Interface{
    .name = "xdg_popup",
    .version = 6,
    .requests = &.{
        .{ .name = "destroy", .sig = "" },
        .{ .name = "grab", .sig = "ou" },
        .{ .name = "reposition", .sig = "ou", .since = 3 },
    },
    .events = &.{
        .{ .name = "configure", .sig = "iiii" },
        .{ .name = "popup_done", .sig = "" },
        .{ .name = "repositioned", .sig = "u", .since = 3 },
    },
};

pub const all = [_]*const Interface{
    &wl_display,                     &wl_registry,                             &wl_callback,                     &wl_compositor,
    &wl_subcompositor,               &wl_subsurface,                           &wl_shm,                          &wl_shm_pool,
    &wl_buffer,                      &wl_surface,                              &wl_region,                       &wl_seat,
    &wl_pointer,                     &wl_keyboard,                             &wl_touch,                        &wl_output,
    &xdg_wm_base,                    &xdg_positioner,                          &xdg_surface,                     &xdg_toplevel,
    &xdg_popup,                      &wl_data_offer,                           &wl_data_source,                  &wl_data_device,
    &wl_data_device_manager,         &zwlr_data_control_offer_v1,              &zwlr_data_control_source_v1,     &zwlr_data_control_device_v1,
    &zwlr_data_control_manager_v1,   &wp_cursor_shape_manager_v1,              &wp_cursor_shape_device_v1,       &wp_viewporter,
    &wp_viewport,                    &wp_fractional_scale_manager_v1,          &wp_fractional_scale_v1,          &zxdg_decoration_manager_v1,
    &zxdg_toplevel_decoration_v1,    &zwp_primary_selection_device_manager_v1, &zwp_primary_selection_device_v1, &zwp_primary_selection_source_v1,
    &zwp_primary_selection_offer_v1, &zwp_relative_pointer_manager_v1,         &zwp_relative_pointer_v1,         &zwp_pointer_constraints_v1,
    &zwp_locked_pointer_v1,          &zwp_confined_pointer_v1,                 &zwp_text_input_manager_v3,       &zwp_text_input_v3,
    &xdg_activation_v1,              &xdg_activation_token_v1,                 &wp_presentation,                 &wp_presentation_feedback,
    &zwp_idle_inhibit_manager_v1,    &zwp_idle_inhibitor_v1,                   &zwp_pointer_gestures_v1,         &zwp_pointer_gesture_swipe_v1,
    &zwp_pointer_gesture_pinch_v1,   &zwp_pointer_gesture_hold_v1,             &zwp_linux_dmabuf_v1,             &zwp_linux_buffer_params_v1,
    &zwp_linux_dmabuf_feedback_v1,   &zxdg_output_manager_v1,                  &zxdg_output_v1,
    &wl_fixes,                       &zxdg_exporter_v2,                        &zxdg_importer_v2,
    &zxdg_exported_v2,               &zxdg_imported_v2,
    &xdg_wm_dialog_v1,               &xdg_dialog_v1,
};

// ─── tests ──────────────────────────────────────────────────────

const t = std.testing;

test "find resolves every table entry, rejects unknowns" {
    for (all) |iface| {
        try t.expectEqual(iface, find(iface.name).?);
    }
    try t.expectEqual(@as(?*const Interface, null), find("gtk_shell1"));
}

test "fd counting" {
    try t.expectEqual(@as(u32, 1), fdCount(wl_shm.requests[0].sig)); // create_pool
    try t.expectEqual(@as(u32, 1), fdCount(wl_keyboard.events[0].sig)); // keymap
    try t.expectEqual(@as(u32, 0), fdCount(wl_surface.requests[1].sig)); // attach
}

test "every 'n' signature names its interface (except registry.bind)" {
    for (all) |iface| {
        for (iface.requests) |*msg| {
            const has_n = std.mem.indexOfScalar(u8, msg.sig, 'n') != null;
            if (iface == &wl_registry) continue;
            try t.expectEqual(has_n, msg.new_id_iface != null);
        }
        // data_offer (the three selection device families) is the
        // only server-created object; every other event creates
        // nothing.
        for (iface.events) |*msg| {
            const has_n = std.mem.indexOfScalar(u8, msg.sig, 'n') != null;
            try t.expectEqual(has_n, msg.new_id_iface != null);
            if (has_n) try t.expect(iface == &wl_data_device or
                iface == &zwlr_data_control_device_v1 or
                iface == &zwp_primary_selection_device_v1 or
                // `created` is never emitted (non-immed create is
                // answered with `failed`); the entry only keeps
                // `failed` at its spec opcode.
                iface == &zwp_linux_buffer_params_v1);
        }
    }
}

test "newIdArg positions" {
    // create_buffer: n is arg 0
    try t.expectEqual(@as(?usize, 0), newIdArg(&wl_shm_pool.requests[0]));
    // registry.bind "usun": n is arg 3
    try t.expectEqual(@as(?usize, 3), newIdArg(&wl_registry.requests[0]));
    // get_popup "n?oo": '?' must not shift the index
    try t.expectEqual(@as(?usize, 0), newIdArg(&xdg_surface.requests[2]));
    // commit creates nothing
    try t.expectEqual(@as(?usize, null), newIdArg(&wl_surface.requests[6]));
}

test "signatures only use known letters" {
    for (all) |iface| {
        for (iface.requests) |*msg| {
            for (msg.sig) |ch| try t.expect(std.mem.indexOfScalar(u8, "iufsonah?", ch) != null);
            try t.expect(msg.since <= iface.version);
        }
        for (iface.events) |*msg| {
            for (msg.sig) |ch| try t.expect(std.mem.indexOfScalar(u8, "iufsonah?", ch) != null);
            try t.expect(msg.since <= iface.version);
        }
    }
}

test "decode a real wl_registry.global event through the tables" {
    var buf: [64]u8 = undefined;
    var b = wire.Builder.init(&buf, 2, 0); // registry id 2, opcode 0 = global
    b.putUint(14);
    b.putString("wl_compositor");
    b.putUint(6);
    const msg = try b.finish();

    const hdr = (try wire.parseHeader(msg)).?;
    const ev = wl_registry.events[hdr.opcode];
    var it = wire.ArgIter.init(msg[wire.header_size..hdr.size], ev.sig);
    try t.expectEqual(@as(u32, 14), (try it.next()).?.uint);
    const iface = find((try it.next()).?.string.?).?;
    try t.expectEqual(&wl_compositor, iface);
    try t.expectEqual(@as(u32, 6), (try it.next()).?.uint);
}
