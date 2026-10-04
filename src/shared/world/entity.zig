//! An entity of the world (DESIGN.md W1, W2): a player, an enemy, a weapon, an item, a piece of
//! scenery, an effect. Its data is typed fields, the same for every kind, and its behaviour's own
//! memory (`mind`), typed by the behaviour (behaviours.zig). A `Handle` names an entity: the
//! entity's place in the world's pool and the place's generation, so that a handle kept after
//! its entity went finds nothing, not the entity that took the place since.
const std = @import("std");
const fixed = @import("fixed.zig");
const content_entity = @import("../content/entity.zig");
const behaviours = @import("behaviours.zig");

const Fixed = fixed.Fixed;
const Vec3 = fixed.Vec3;

pub const Team = content_entity.Team;

pub const Facing = enum(u1) {
    right,
    left,

    pub fn turned(f: Facing) Facing {
        return if (f == .right) .left else .right;
    }

    /// 1 facing right, -1 facing left.
    pub fn sign(f: Facing) i32 {
        return if (f == .right) 1 else -1;
    }
};

/// The most entities a world holds at once: room for the original's 66 objects and more
/// (DESIGN.md W1).
pub const capacity = 128;

/// A kind of entity, by its index in the world's kinds (kinds.zig).
pub const KindId = u8;

/// An entity's name while it is in the world: its place in the pool and that place's
/// generation, which changes each time the place is freed.
pub const Handle = struct {
    index: u8,
    generation: u16,

    pub fn eql(a: Handle, b: Handle) bool {
        return a.index == b.index and a.generation == b.generation;
    }

    pub fn format(h: Handle, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("#{d}.{d}", .{ h.index, h.generation });
    }
};

/// How the world treats an entity.
pub const Flags = packed struct(u16) {
    /// Not drawn, and kept off the ground's depths rule.
    hidden: bool = false,
    /// Drawn at its place on the screen, which the camera does not move.
    on_screen: bool = false,
    /// Drawn in front of the layers' cells that are in front of the sprites.
    in_front: bool = false,
    /// Stays in the world when it is far off the screen (draw_list.zig).
    stays: bool = false,
    /// Among the entities at its depth, drawn behind the others at the next drawing only
    /// (draw_list.zig's order).
    behind: bool = false,
    /// In the air: its gravity pulls it, and it lands on the ground.
    airborne: bool = false,
    /// It landed at this tick's movement.
    landed: bool = false,
    /// Its behaviour asks to grab what is in front of it, or to pick up what is under it, at
    /// this tick (the grabs and pick-ups systems answer, then clear the asks).
    wants_grab: bool = false,
    wants_pickup: bool = false,
    /// It does not move by its speed at this tick: its behaviour holds it still and keeps its
    /// speed (the original's objects move only when their code moves them).
    still: bool = false,
    _: u6 = 0,
};

/// The animation an entity plays: one of its kind's, the frame it is on, and the logic ticks
/// that frame still shows.
pub const Animation = struct {
    /// The animation, by its index in the kind's definition; null: none, the entity shows
    /// nothing.
    index: ?u8 = null,
    frame: u8 = 0,
    /// The ticks the frame shows from now on, this one included.
    left: u8 = 0,
    /// It has shown all its frames once (a looping one has started again).
    done: bool = false,
    /// It holds the frame it is on: its behaviour sets its frames (the original's objects
    /// whose animation stops while their code poses them).
    paused: bool = false,
    /// The ticks each frame shows, set by its behaviour for all the frames (the original's
    /// objects pace their animation themselves); null: each frame's own.
    pace: ?u8 = null,
};

/// The boxes in use (DESIGN.md W2): those of the frame the entity last showed, or of the first
/// frame of an animation that started since, by their index in the kind's definition, and
/// whether they are mirrored (the frame drawn mirrored).
pub const Boxes = struct {
    body: ?u8 = null,
    attack: ?u8 = null,
    mirrored: bool = false,
};

pub const Entity = struct {
    /// The place's generation (see `Handle`).
    generation: u16 = 0,
    /// Its kind; null: the place is free.
    kind: ?KindId = null,
    team: Team = .neutral,
    position: Vec3 = .zero,
    /// Per logic tick.
    velocity: Vec3 = .zero,
    facing: Facing = .right,
    health: i16 = 0,
    flags: Flags = .{},
    animation: Animation = .{},
    /// The move under way, by its index in the kind's definition.
    move: ?u8 = null,
    boxes: Boxes = .{},
    /// Added to its frames' palettes.
    palette: u2 = 0,
    /// The grab: the entity holding this one, and the one this one holds.
    holder: ?Handle = null,
    holding: ?Handle = null,
    /// The last entity whose blow landed on it.
    struck_by: ?Handle = null,
    /// Its behaviour's state and memory.
    mind: behaviours.Mind = .none,

    pub fn alive(e: *const Entity) bool {
        return e.kind != null;
    }

    pub fn facingLeft(e: *const Entity) bool {
        return e.facing == .left;
    }
};

test "a handle prints as its place and generation" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("#3.7", try std.fmt.bufPrint(&buf, "{f}", .{Handle{ .index = 3, .generation = 7 }}));
    try std.testing.expectEqual(Facing.left, Facing.right.turned());
    try std.testing.expectEqual(@as(i32, -1), Facing.left.sign());
}
