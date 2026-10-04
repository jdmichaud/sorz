//! The world of a round (DESIGN.md 10.3): its entities in a fixed pool, the two players, the
//! camera and the round's script. It is a value, its fields named and typed, with no pointer: its
//! canonical form (canonical.zig) is what the tests, the replays and network play compare.
//!
//! The content the world reads (its kinds, kinds.zig), the random generator (the game's one, which
//! the screens before play draw from too) and the tick's output (output.zig) are given to each
//! tick: systems.zig runs a logic tick over them.
const std = @import("std");
const canonical = @import("../canonical.zig");
const input = @import("../input.zig");
const fixed = @import("fixed.zig");
const entity = @import("entity.zig");
const kinds_mod = @import("kinds.zig");
const behaviours = @import("behaviours.zig");

const Fixed = fixed.Fixed;
const Vec3 = fixed.Vec3;
const Entity = entity.Entity;
const Handle = entity.Handle;
const KindId = entity.KindId;
const Kinds = kinds_mod.Kinds;

pub const capacity = entity.capacity;

/// What a player asks for at a logic tick: the buttons held, and those newly pressed.
pub const Command = struct {
    held: input.Pad = .{},
    pressed: input.Pad = .{},
};

pub const Player = struct {
    /// The entity the player plays, if any.
    entity: ?Handle = null,
    lives: u8 = 0,
    specials: u8 = 0,
    score: u32 = 0,
    /// The command of this tick.
    command: Command = .{},
    /// The pad as read at the last display tick, which the next read's presses are new against.
    last: input.Pad = .{},
};

/// The view of the round: its top-left corner, and how far it may go.
pub const Camera = struct {
    x: Fixed = .zero,
    y: Fixed = .zero,
    /// Across, to the wall it stops at until the section is cleared; and down.
    x_min: Fixed = .zero,
    x_max: Fixed = .of(std.math.maxInt(i32)),
    y_min: Fixed = .zero,
    y_max: Fixed = .of(std.math.maxInt(i32)),
    /// It follows the players across (in play), from where the last tick drew them, and never
    /// goes back: its limit on the left follows it.
    follows: bool = false,
    drawn: [2]?Fixed = .{ null, null },
    /// The special attack's run, while it lasts: the camera neither follows nor holds the players.
    run: ?Run = null,
    /// A shake under way (`Tick.shake`): its ticks left.
    shake: u8 = 0,

    /// The special attack's run (behaviours/police_car.zig): called, the camera follows for the
    /// tick of the call; then it runs back across at `speed` to `limit`; then (its effect over) it
    /// runs ahead at that speed until it is back where it was at the call.
    pub const Run = struct {
        from: Fixed,
        state: enum { called, back, ahead } = .called,
        speed: Fixed = .zero,
        limit: Fixed = .zero,
    };
};

/// The round's script's place in the round (PLAN item 13 fills it in).
pub const Script = struct {
    /// The stretch between two walls of the camera.
    section: u8 = 0,
};

pub const World = struct {
    /// Logic ticks since the world began.
    tick: u32 = 0,
    entities: [capacity]Entity = @splat(.{}),
    players: [2]Player = @splat(.{}),
    camera: Camera = .{},
    script: Script = .{},
    /// The ground's height, until the round's floor gives it place by place (PLAN item 13).
    ground: Fixed = .zero,
    /// A special attack is under way (play's phase `special`): the players stand still, the
    /// enemies it caught wait for its blast.
    special: bool = false,

    pub const Full = error{Full};

    /// The entity `h` names, or null when it has gone.
    pub fn get(self: *World, h: Handle) ?*Entity {
        if (h.index >= capacity) return null;
        const e = &self.entities[h.index];
        if (!e.alive() or e.generation != h.generation) return null;
        return e;
    }

    pub fn getConst(self: *const World, h: Handle) ?*const Entity {
        return @constCast(self).get(h);
    }

    /// The handle of the entity at place `index`, or null when the place is free.
    pub fn handleAt(self: *const World, index: usize) ?Handle {
        const e = &self.entities[index];
        if (!e.alive()) return null;
        return .{ .index = @intCast(index), .generation = e.generation };
    }

    /// A new entity of `kind` at `position`, facing `facing`, in the first free place: its
    /// team, health and palette from its definition, its behaviour at its first state, its
    /// definition's first animation started.
    pub fn spawn(self: *World, kinds: *const Kinds, kind: KindId, position: Vec3, facing: entity.Facing) Full!Handle {
        const index = for (&self.entities, 0..) |*e, i| {
            if (!e.alive()) break i;
        } else return error.Full;
        const k = kinds.get(kind);
        const e = &self.entities[index];
        e.* = .{
            .generation = e.generation,
            .kind = kind,
            .team = k.definition.team,
            .position = position,
            .facing = facing,
            .health = k.definition.health,
            .palette = k.definition.palette,
            .mind = behaviours.initial(k.behaviour),
        };
        if (k.definition.animations.len != 0) kinds.startAnimation(e, 0);
        return .{ .index = @intCast(index), .generation = e.generation };
    }

    /// The entity goes: its place is freed, its handles find nothing, and a grab it was in ends.
    pub fn remove(self: *World, h: Handle) void {
        const e = self.get(h) orelse return;
        e.* = .{ .generation = e.generation +% 1 };
        for (&self.entities) |*other| {
            if (other.holder) |x| if (x.eql(h)) {
                other.holder = null;
            };
            if (other.holding) |x| if (x.eql(h)) {
                other.holding = null;
            };
        }
    }

    /// The entities in the order the world updates them: the players', player 1's first, then
    /// the others in their places' order. Returns their places.
    pub fn updateOrder(self: *const World, buf: *[capacity]u8) []const u8 {
        var n: usize = 0;
        var player_place: [2]?usize = .{ null, null };
        for (self.players, 0..) |p, k| {
            const h = p.entity orelse continue;
            if (self.getConst(h) == null) continue;
            if (k == 1 and player_place[0] == h.index) continue;
            player_place[k] = h.index;
            buf[n] = h.index;
            n += 1;
        }
        for (&self.entities, 0..) |*e, i| {
            if (!e.alive()) continue;
            if (player_place[0] == i or player_place[1] == i) continue;
            buf[n] = @intCast(i);
            n += 1;
        }
        return buf[0..n];
    }

    /// The player who plays the entity `h`, if any.
    pub fn playerOf(self: *const World, h: Handle) ?u1 {
        for (self.players, 0..) |p, k| {
            if (p.entity) |x| if (x.eql(h)) return @intCast(k);
        }
        return null;
    }

    /// The hash of the world's canonical form.
    pub fn hash(self: *const World) u64 {
        return canonical.hash(World, self);
    }
};
