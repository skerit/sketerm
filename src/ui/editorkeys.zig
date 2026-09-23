//! The editor face's key-binding table: every `editor/commands.zig`
//! command's default accelerators, overlaid with `editor_keybind.*`
//! config entries.
//!
//! A separate table from the window/pane bindings on purpose: these
//! chords exist only while the editor canvas has focus and can never eat
//! a terminal key.

const std = @import("std");
const c = @import("../c.zig").c;
const input = @import("input.zig");
const ecmd = @import("../editor/commands.zig");
const diag = @import("../util/diag.zig");

pub const Binding = struct {
    keyval: c_uint,
    mods: c_uint,
    cmd: ecmd.Command,
};

pub const Table = struct {
    items: std.ArrayList(Binding) = .empty,

    pub fn deinit(self: *Table, alloc: std.mem.Allocator) void {
        self.items.deinit(alloc);
    }

    /// Rebuild from the defaults plus `overrides` (any slice whose
    /// elements carry `.name` and `.accel`). An override replaces EVERY
    /// default chord of its command, an empty accel unbinds it, and
    /// overrides are listed FIRST so one that reuses another command's
    /// default chord wins it.
    pub fn rebuild(self: *Table, alloc: std.mem.Allocator, overrides: anytype) void {
        self.items.clearRetainingCapacity();
        for (overrides, 0..) |kb, idx| {
            const cmd = ecmd.fromName(kb.name) orelse {
                diag.print("sketerm: editor_keybind: unknown command '{s}'\n", .{kb.name});
                continue;
            };
            // The LAST entry for a command is the one in force.
            if (lastOverride(overrides, cmd) != idx) continue;
            if (kb.accel.len == 0) continue;
            self.add(alloc, cmd, kb.accel);
        }
        for (0..ecmd.COMMAND_COUNT) |i| {
            const cmd: ecmd.Command = @enumFromInt(i);
            if (lastOverride(overrides, cmd) != null) continue;
            for (ecmd.defaultAccels(cmd)) |accel| self.add(alloc, cmd, accel);
        }
    }

    /// Index of the last override naming `cmd`.
    fn lastOverride(overrides: anytype, cmd: ecmd.Command) ?usize {
        var found: ?usize = null;
        for (overrides, 0..) |kb, idx| {
            if (std.mem.eql(u8, kb.name, ecmd.name(cmd))) found = idx;
        }
        return found;
    }

    fn add(self: *Table, alloc: std.mem.Allocator, cmd: ecmd.Command, accel: []const u8) void {
        const p = input.parseAccel(accel) orelse {
            diag.print("sketerm: editor_keybind: bad accelerator '{s}' for '{s}'\n", .{ accel, ecmd.name(cmd) });
            return;
        };
        self.items.append(alloc, .{
            .keyval = p.keyval,
            .mods = p.mods & input.SIGNIFICANT_MODS,
            .cmd = cmd,
        }) catch return;
    }

    /// The command bound to a key event, trying the lowercased keyval
    /// first (GTK reports uppercase keysyms under Shift; the table is
    /// lowercase). `mods` is already masked to `SIGNIFICANT_MODS`.
    pub fn match(self: *const Table, keyval: c_uint, lower: c_uint, mods: c_uint) ?ecmd.Command {
        for (self.items.items) |b| {
            if (b.keyval == lower and b.mods == mods) return b.cmd;
        }
        for (self.items.items) |b| {
            if (b.keyval == keyval and b.mods == mods) return b.cmd;
        }
        return null;
    }

    /// First chord bound to `cmd` in force, or null when it is unbound.
    pub fn chordOf(self: *const Table, cmd: ecmd.Command) ?Binding {
        for (self.items.items) |b| {
            if (b.cmd == cmd) return b;
        }
        return null;
    }
};

// ======================================================================
// Tests
// ======================================================================

const testing = std.testing;
const Override = struct { name: []const u8, accel: []const u8 };

test "editorkeys: every default chord parses and no two commands share one" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    t.rebuild(testing.allocator, @as([]const Override, &.{}));
    var expected: usize = 0;
    for (0..ecmd.COMMAND_COUNT) |i| expected += ecmd.defaultAccels(@enumFromInt(i)).len;
    // A bad accelerator is dropped with a warning; none may be.
    try testing.expectEqual(expected, t.items.items.len);
    for (t.items.items, 0..) |a, i| {
        for (t.items.items[i + 1 ..]) |b| {
            if (a.keyval == b.keyval and a.mods == b.mods) {
                std.debug.print("{s} and {s} share a default chord\n", .{ ecmd.name(a.cmd), ecmd.name(b.cmd) });
                return error.DefaultChordCollision;
            }
        }
    }
}

test "editorkeys: an override moves a command and wins a shared chord" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const overrides = [_]Override{
        .{ .name = "goto_definition", .accel = "<Control>b" },
        // Ctrl+I is show_hover's default: the override takes it.
        .{ .name = "toggle_comment", .accel = "<Control>i" },
        .{ .name = "sort_lines", .accel = "" },
    };
    t.rebuild(testing.allocator, @as([]const Override, &overrides));
    try testing.expectEqual(ecmd.Command.goto_definition, t.match(c.GDK_KEY_b, c.GDK_KEY_b, c.GDK_CONTROL_MASK).?);
    // F12 no longer means anything.
    try testing.expect(t.match(c.GDK_KEY_F12, c.GDK_KEY_F12, 0) == null);
    try testing.expectEqual(ecmd.Command.toggle_comment, t.match(c.GDK_KEY_i, c.GDK_KEY_i, c.GDK_CONTROL_MASK).?);
    // Unbound: F9 falls through.
    try testing.expect(t.match(c.GDK_KEY_F9, c.GDK_KEY_F9, 0) == null);
    try testing.expect(t.chordOf(.sort_lines) == null);
}

test "editorkeys: a shifted keysym matches its lowercase binding" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    t.rebuild(testing.allocator, @as([]const Override, &.{}));
    // Ctrl+Shift+Z arrives as an uppercase Z.
    try testing.expectEqual(ecmd.Command.redo, t.match(c.GDK_KEY_Z, c.GDK_KEY_z, c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK).?);
    // Ctrl+Shift+[ arrives as braceleft on a US layout.
    try testing.expectEqual(ecmd.Command.fold, t.match(c.GDK_KEY_braceleft, c.GDK_KEY_braceleft, c.GDK_CONTROL_MASK | c.GDK_SHIFT_MASK).?);
}
