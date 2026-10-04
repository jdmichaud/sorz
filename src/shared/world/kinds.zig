//! The kinds of entity a world may hold (DESIGN.md W3): the content's definitions
//! (content/entity.zig) bound to their art and to their behaviours. Binding checks that each
//! definition gives what its behaviour reads (its animations, moves, numbers and sounds, by the
//! names the behaviour declares), and turns those names into indices, so that a behaviour reaches
//! its numbers and animations by a typed name and without a search; a definition that lacks one
//! is refused, naming its file and the missing field.
const std = @import("std");
const art = @import("../content/art.zig");
const json = @import("../formats/json.zig");
const content_entity = @import("../content/entity.zig");
const fixed = @import("fixed.zig");
const entity = @import("entity.zig");
const behaviours = @import("behaviours.zig");

const Definition = content_entity.Definition;
const Entity = entity.Entity;
const KindId = entity.KindId;

pub const Kind = struct {
    definition: *const Definition,
    behaviour: behaviours.Behaviour,
    /// Each animation's frames' art, by animation and frame.
    frames: []const []const *const art.Frame,
    /// The behaviour's names, in the order it declares them, as the definition's indices: its
    /// animations, its moves, its numbers' values and its sounds' names.
    animation_of: []const u8 = &.{},
    move_of: []const u8 = &.{},
    numbers: []const i32 = &.{},
    sound_of: []const []const u8 = &.{},

    pub fn name(k: *const Kind) []const u8 {
        return k.definition.name;
    }

    pub fn family(k: *const Kind) content_entity.Family {
        return k.definition.family;
    }
};

pub const Error = json.Error;

pub const Kinds = struct {
    list: []const Kind = &.{},
    /// The frame of the shadows on the ground, when the content has one.
    shadow: ?*const art.Frame = null,

    pub fn get(self: *const Kinds, id: KindId) *const Kind {
        return &self.list[id];
    }

    pub fn find(self: *const Kinds, kind_name: []const u8) ?KindId {
        for (self.list, 0..) |*k, i| if (std.mem.eql(u8, k.name(), kind_name)) return @intCast(i);
        return null;
    }

    /// Binds `definitions` (at most 256) to the art `a`; a refusal names the definition's file
    /// and field in `diag`.
    pub fn bind(arena: std.mem.Allocator, definitions: []const Definition, a: *const art.Art, diag: *json.Diagnostic) Error!Kinds {
        if (definitions.len > std.math.maxInt(KindId) + 1) {
            diag.* = .{ .file = "manifest.json", .message = "more than 256 kinds of entity" };
            return error.BadAsset;
        }
        const list = try arena.alloc(Kind, definitions.len);
        for (list, definitions) |*k, *d| {
            const file = try content_entity.path(arena, d.name);
            const behaviour = std.meta.stringToEnum(behaviours.Behaviour, d.behaviour) orelse
                return refuse(diag, file, "behaviour", "no behaviour of this name");
            const frames = try arena.alloc([]const *const art.Frame, d.animations.len);
            for (frames, d.animations, 0..) |*f, an, i| {
                const out = try arena.alloc(*const art.Frame, an.frames.len);
                for (out, an.frames, 0..) |*o, step, j| {
                    o.* = a.frame(step.frame) orelse {
                        diag.* = .{ .file = file, .message = "no sprite frame of this name" };
                        diag.setPlace("animations.{s}.frames[{d}].frame", .{ d.animations[i].name, j });
                        return error.BadAsset;
                    };
                }
                f.* = out;
            }
            k.* = .{ .definition = d, .behaviour = behaviour, .frames = frames };
            switch (behaviour) {
                inline else => |b| try bindNames(arena, behaviours.module(b), k, file, diag),
            }
        }
        return .{ .list = list };
    }

    /// Starts animation `index` of `e`'s kind from its first frame; that frame's boxes are in
    /// use at once.
    pub fn startAnimation(self: *const Kinds, e: *Entity, index: u8) void {
        const k = self.get(e.kind.?);
        const step = k.definition.animations[index].frames[0];
        e.animation = .{ .index = index, .frame = 0, .left = step.ticks, .paused = e.animation.paused, .pace = null };
        e.boxes = .{ .body = step.body, .attack = step.attack, .mirrored = e.facingLeft() != step.flip };
    }
};

fn refuse(diag: *json.Diagnostic, file: []const u8, field: []const u8, message: []const u8) Error {
    diag.* = .{ .file = file, .message = message };
    diag.setPlace("{s}", .{field});
    return error.BadAsset;
}

/// The behaviour `M`'s names in `k`'s definition (behaviours.zig says what a module declares).
fn bindNames(arena: std.mem.Allocator, comptime M: type, k: *Kind, file: []const u8, diag: *json.Diagnostic) Error!void {
    const d = k.definition;
    const behaviour = comptime @tagName(behaviours.tagOf(M));
    const missing = "missing: the behaviour " ++ behaviour ++ " reads it";
    if (@hasDecl(M, "Animation")) {
        const names = comptime std.meta.fieldNames(M.Animation);
        const out = try arena.alloc(u8, names.len);
        inline for (names, 0..) |n, i| out[i] = d.animation(n) orelse return refuse(diag, file, "animations." ++ n, missing);
        k.animation_of = out;
    }
    if (@hasDecl(M, "Move")) {
        const names = comptime std.meta.fieldNames(M.Move);
        const out = try arena.alloc(u8, names.len);
        inline for (names, 0..) |n, i| out[i] = d.move(n) orelse return refuse(diag, file, "moves." ++ n, missing);
        k.move_of = out;
    }
    if (@hasDecl(M, "Numbers")) {
        const fields = comptime @typeInfo(M.Numbers).@"struct".field_names;
        const types = comptime @typeInfo(M.Numbers).@"struct".field_types;
        const out = try arena.alloc(i32, fields.len);
        inline for (fields, types, 0..) |n, T, i| {
            const v = d.number(n) orelse return refuse(diag, file, "numbers." ++ n, missing);
            if (T != fixed.Fixed and std.math.cast(T, v) == null) return refuse(diag, file, "numbers." ++ n, "out of range for the behaviour " ++ behaviour);
            out[i] = v;
        }
        k.numbers = out;
    }
    if (@hasDecl(M, "Sound")) {
        const names = comptime std.meta.fieldNames(M.Sound);
        const out = try arena.alloc([]const u8, names.len);
        inline for (names, 0..) |n, i| out[i] = d.sound(n) orelse return refuse(diag, file, "sounds." ++ n, missing);
        k.sound_of = out;
    }
}

/// The numbers of a kind for behaviour `M`, typed as `M.Numbers` declares them.
pub fn numbersOf(comptime M: type, k: *const Kind) M.Numbers {
    var out: M.Numbers = undefined;
    const info = @typeInfo(M.Numbers).@"struct";
    inline for (info.field_names, info.field_types, 0..) |n, T, i| {
        @field(out, n) = if (T == fixed.Fixed) fixed.Fixed.of(k.numbers[i]) else @intCast(k.numbers[i]);
    }
    return out;
}
