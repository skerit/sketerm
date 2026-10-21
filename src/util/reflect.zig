//! Container reflection that reads the same on Zig 0.16 and 0.17.
//!
//! 0.17 reshaped `std.builtin.Type` into struct-of-arrays (`field_names`,
//! `field_types`, `field_values`, `decl_names`) and turned `std.meta.fields`
//! into a compile error, so `@typeInfo(T).@"enum".fields` compiles on exactly
//! one of the two. Every field walk goes through here instead; once 0.16
//! support is dropped the callers can move to the 0.17 arrays directly.

const std = @import("std");

const soa = @hasField(std.builtin.Type.Enum, "field_names");

/// What `@Struct` takes per field; one shape on both versions, under two names.
pub const StructFieldAttributes = if (soa) std.builtin.Type.Struct.FieldAttributes else std.builtin.Type.StructField.Attributes;

/// One field of an enum, struct or union. `value` is meaningful for enums
/// only, `type` for structs and unions only, `attrs` for structs only.
pub const Field = struct {
    name: [:0]const u8,
    type: type = void,
    value: comptime_int = 0,
    attrs: StructFieldAttributes = .{},

    /// The struct field's default value, or null when it has none.
    pub inline fn defaultValue(comptime f: Field) ?f.type {
        const dp: *const f.type = @ptrCast(@alignCast(f.attrs.default_value_ptr orelse return null));
        return dp.*;
    }
};

/// The fields of enum, struct or union `T`, in declaration order.
/// `inline` so the slice stays comptime-known at runtime call sites,
/// which `inline for` over it requires.
pub inline fn fields(comptime T: type) []const Field {
    return comptime fieldList(T);
}

fn fieldList(comptime T: type) []const Field {
    comptime {
        const info = @typeInfo(T);
        const len = switch (info) {
            inline .@"enum", .@"struct", .@"union" => |c| if (soa) c.field_names.len else c.fields.len,
            else => @compileError("reflect.fields: " ++ @typeName(T) ++ " is not an enum, struct or union"),
        };
        var out: [len]Field = undefined;
        for (&out, 0..) |*f, i| f.* = switch (info) {
            .@"enum" => |e| if (soa)
                .{ .name = e.field_names[i], .value = e.field_values[i] }
            else
                .{ .name = e.fields[i].name, .value = e.fields[i].value },
            .@"struct" => |s| if (soa)
                .{ .name = s.field_names[i], .type = s.field_types[i], .attrs = s.field_attrs[i] }
            else
                .{ .name = s.fields[i].name, .type = s.fields[i].type, .attrs = .{
                    .@"comptime" = s.fields[i].is_comptime,
                    .@"align" = s.fields[i].alignment,
                    .default_value_ptr = s.fields[i].default_value_ptr,
                } },
            .@"union" => |u| if (soa)
                .{ .name = u.field_names[i], .type = u.field_types[i] }
            else
                .{ .name = u.fields[i].name, .type = u.fields[i].type },
            else => unreachable,
        };
        const final = out;
        return &final;
    }
}

/// The names of `T`'s public declarations.
pub inline fn declNames(comptime T: type) []const [:0]const u8 {
    return comptime declList(T);
}

fn declList(comptime T: type) []const [:0]const u8 {
    comptime {
        const decls = switch (@typeInfo(T)) {
            inline .@"enum", .@"struct", .@"union", .@"opaque" => |c| if (soa) c.decl_names else c.decls,
            else => @compileError("reflect.declNames: " ++ @typeName(T) ++ " has no declarations"),
        };
        if (soa) return decls;
        var out: [decls.len][:0]const u8 = undefined;
        for (&out, decls) |*n, d| n.* = d.name;
        const final = out;
        return &final;
    }
}

/// The default value of struct field `name`, or null when it has none.
pub inline fn defaultValue(comptime T: type, comptime name: []const u8) ?@FieldType(T, name) {
    return comptime defaultOf(T, name);
}

fn defaultOf(comptime T: type, comptime name: []const u8) ?@FieldType(T, name) {
    comptime {
        const s = @typeInfo(T).@"struct";
        const i = std.meta.fieldIndex(T, name) orelse @compileError(@typeName(T) ++ " has no field " ++ name);
        const ptr = if (soa) s.field_attrs[i].default_value_ptr else s.fields[i].default_value_ptr;
        const p: *const @FieldType(T, name) = @ptrCast(@alignCast(ptr orelse return null));
        return p.*;
    }
}

test "fields walks enums, structs and unions alike" {
    const E = enum(u8) { a = 3, b = 7 };
    const S = struct { x: u8, y: []const u8 };
    const U = union(enum) { p: u16, q: void };
    comptime {
        const ef = fields(E);
        std.debug.assert(ef.len == 2 and ef[1].value == 7 and std.mem.eql(u8, ef[0].name, "a"));
        const sf = fields(S);
        std.debug.assert(sf.len == 2 and sf[1].type == []const u8);
        const uf = fields(U);
        std.debug.assert(uf[0].type == u16 and std.mem.eql(u8, uf[1].name, "q"));
    }
}

test "declNames and defaultValue" {
    const S = struct {
        n: u32 = 42,
        m: u8,
        pub const K = 1;
        pub fn f() void {}
    };
    comptime {
        const d = declNames(S);
        std.debug.assert(d.len == 2 and std.mem.eql(u8, d[0], "K"));
        std.debug.assert(defaultValue(S, "n").? == 42 and defaultValue(S, "m") == null);
    }
}
