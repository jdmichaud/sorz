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
    /// Not drawn at this tick, a blink's dark phase: unlike `hidden`, it keeps its frame's boxes
    /// and its place (the original's blinking objects are only not drawn).
    blinked: bool = false,
    /// It stops whoever walks into it, within its definition's `solid` box (a breakable
    /// standing).
    solid: bool = false,
    /// It moves across and in height alone at this tick, its speed in depth kept (the
    /// original's knock-downs and throws leave the depth as it was).
    keeps_depth: bool = false,
    /// Its kind's shadow is not drawn (an enemy behind its shutter until it lands).
    shadowless: bool = false,
    /// Its blows land but do no damage: the original never set its power (a trio's others,
    /// acrobat_trio.zig).
    harmless: bool = false,
    _: u1 = 0,
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

/// The way an enemy comes in, as the round's script places it (DESIGN.md W6): what it does once
/// it is out of hiding. Each kind's behaviour reads the ways it has; a kind placed with a way it
/// does not have takes its first.
pub const Entrance = enum(u8) {
    /// It heads for its place beside its target.
    approach,
    /// It closes in on its target at once.
    close_in,
    /// It waits at the screen's far edge for its target to come near.
    edge,
    /// It waits, facing its target, until it comes near or a while passes.
    wait,
    /// It lies in wait behind a rolling shutter, and drops out when its target comes near.
    shutter,
    /// It squares up to its target first.
    square_up,
    /// It jumps in at its target.
    jump_in,
    /// It sizes its target up first.
    size_up,
    /// It follows its target, keeping its distance.
    follow,
    /// It leaps in from the screen's edge, or drops from above.
    enter,
    /// It circles its target first.
    circle,
};

/// What else the round's script says of an enemy or a piece of scenery it places, each by its
/// meaning (the kinds read those they have).
pub const Traits = packed struct(u16) {
    /// It stays hidden until the camera reaches its place across (else, until its place is on
    /// the screen).
    waits_for_camera: bool = false,
    /// It closes in slower (a Galsia, an acrobat), and an acrobat leaps in only from nearer.
    slow: bool = false,
    /// A stalker that has lurked closes in to strike instead of walking off.
    closes_in_after_lurking: bool = false,
    /// A pipe Galsia fights with the other pipe, and its own moves.
    pipe_b: bool = false,
    /// Signal slides in at a target level with it.
    slides: bool = false,
    /// An acrobat flips away from a knock-down.
    flips_away: bool = false,
    /// An acrobat drops in from above.
    drops_in: bool = false,
    /// An acrobat flips at a target that comes near while it circles.
    flips_at_close_range: bool = false,
    /// A brawler shrugs blows off without reeling.
    unflinching: bool = false,
    /// A brawler walks off after its punches.
    walks_off: bool = false,
    /// A boss is the second of twins.
    twin: bool = false,
    /// A piece of scenery stirs while a flight passes (`World.flight`).
    stirs: bool = false,
    /// A juggler juggles the other knives.
    knives_b: bool = false,
    _: u3 = 0,
};

/// A thing flying or swung as a blow: a body thrown, a weapon in the hand or thrown. What its
/// attack box meets takes `damage`, as a blow of `by` (the one who threw or swings it), and
/// reacts as `reaction` says (knocked down; the pepper's, sneezing); it lands on the enemies of
/// `by` (and, `on_players`, on the players but `by`).
pub const Missile = struct {
    by: Handle,
    damage: u8,
    on_players: bool = false,
    reaction: content_entity.Reaction = .knock_down,
};

/// How the round's script placed an enemy: its way in, its traits, its place beside its target
/// (pixels across, on the side it comes from, and in depth), and its strength (the row of its
/// kind's health, damage and points).
pub const Spawn = struct {
    entrance: Entrance = .approach,
    traits: Traits = .{},
    offset_x: i16 = 0,
    offset_depth: i16 = 0,
    /// The indices of its offsets in its kind's table, for a kind that counts on from them.
    offset_nibbles: ?u8 = null,
    strength: u2 = 0,
    /// A boss's entry in the status bar's names and bars.
    bar: ?u8 = null,
    /// An enemy's colours, by their number (play's `enemy_colours`), whose line it takes as it
    /// appears (script.zig); null: its kind's own.
    colours: ?u8 = null,
    /// A piece of scenery's height, which it takes as it starts (on a wall); null: the ground.
    height: ?i16 = null,
    /// How a drifting piece of scenery moves.
    drift: Drift = .still,
    /// An enemy's art, by its number (script.zig's art slots).
    art: ?u8 = null,
};

/// How a drifting piece of scenery moves (content/round.zig's `Drift`).
pub const Drift = enum { still, drifts, stops, waves };

/// The boxes in use (DESIGN.md W2): those of the frame the entity last showed, or of the first
/// frame of an animation that started since, by their index in the kind's definition, and
/// whether they are mirrored (the frame drawn mirrored).
pub const Boxes = struct {
    body: ?u8 = null,
    attack: ?u8 = null,
    mirrored: bool = false,
    /// Where they stand, when not at the entity's place: a player's stay where the player stood
    /// at its own turn until its next, though the camera, a holder or the other player moves it
    /// (the original's players set their boxes in the world at their own turn).
    at: ?Vec3 = null,
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
    /// How the round's script placed it (an enemy, a piece of scenery).
    spawn: Spawn = .{},
    /// It flies or is swung as a blow.
    missile: ?Missile = null,
    /// The damage its blows do, for a kind whose blows all do the same (an enemy's, from its
    /// strength, kept when it loses its weapon); 0: each move's own.
    power: u8 = 0,
    /// Its behaviour's state and memory.
    mind: behaviours.Mind = .none,

    pub fn alive(e: *const Entity) bool {
        return e.kind != null;
    }

    /// The world's places in the canonical form (canonical.zig, a pool): the entities, each at
    /// its place; of a free place, its generation alone (the next entity there takes it).
    pub const canonical_pool = struct {
        pub fn inUse(e: *const Entity) bool {
            return e.alive();
        }
        pub const Kept = struct { generation: u16 = 0 };
        pub fn kept(e: *const Entity) Kept {
            return .{ .generation = e.generation };
        }
        pub fn free(k: Kept) Entity {
            return .{ .generation = k.generation };
        }
    };

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
