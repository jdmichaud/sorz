//! A logic tick's context: the world, its kinds, the random generator, the pads and the tick's
//! output, with what the systems and the behaviours share (DESIGN.md W3, W4): an entity's
//! behaviour reached through its hooks, and the `Actor` a behaviour acts through.
//!
//! An actor is an entity seen by its behaviour `M` (behaviours.zig): its fields, its kind, its
//! memory typed as `M.Mind`, and the behaviour's names typed as `M` declares them
//! (`a.animate(.walk)`, `a.startMove(.punch)`, `a.numbers().reach`, `a.sound(.hurt)`), each
//! bound to the definition's data when the kinds were bound (kinds.zig).
const std = @import("std");
const input = @import("../input.zig");
const content_entity = @import("../content/entity.zig");
const fixed = @import("fixed.zig");
const random = @import("random.zig");
const entity = @import("entity.zig");
const kinds_mod = @import("kinds.zig");
const world_mod = @import("world.zig");
const output = @import("output.zig");
const behaviours = @import("behaviours.zig");

const Fixed = fixed.Fixed;
const Vec3 = fixed.Vec3;
const Entity = entity.Entity;
const Handle = entity.Handle;
const Kind = kinds_mod.Kind;
const Kinds = kinds_mod.Kinds;
const World = world_mod.World;
const Command = world_mod.Command;
const Output = output.Output;

/// The pads of a logic tick, as read at its two display ticks in play, in their order (the
/// systems' `commands` says how a player reads them).
pub const Input = struct {
    pads: [2]input.Pads = .{ .{}, .{} },

    /// The same pads at both display ticks.
    pub fn steady(pads: input.Pads) Input {
        return .{ .pads = .{ pads, pads } };
    }
};

/// A blow that meets an entity's body (the hits system).
pub const Blow = struct {
    attacker: Handle,
    damage: i16,
    reaction: content_entity.Reaction,
    /// The speed it gives: across, away from the attacker, and in height.
    push: Vec3,
};

pub const Tick = struct {
    world: *World,
    kinds: *const Kinds,
    random: *random.Random,
    out: *Output,
    input: Input = .{},

    pub fn kindOf(t: *const Tick, e: *const Entity) *const Kind {
        return t.kinds.get(e.kind.?);
    }

    /// A number drawn for `purpose`, noted in the tick's draws.
    pub fn draw(t: *Tick, comptime purpose: random.Purpose) u16 {
        return t.random.draw(purpose, &t.out.draws);
    }

    pub fn pick(t: *Tick, comptime purpose: random.Purpose, comptime n: u16) u16 {
        return t.random.pick(purpose, n, &t.out.draws);
    }

    /// Asks for the sound `name` of the sound content.
    pub fn sound(t: *Tick, name: []const u8, by: ?Handle) void {
        t.out.sounds.append(.{ .name = name, .by = by });
    }

    /// Starts move `index` of `e`'s kind: its animation from the first frame, its sound.
    pub fn startMove(t: *Tick, h: Handle, e: *Entity, index: u8) void {
        const m = t.kindOf(e).definition.moves[index];
        e.move = index;
        t.kinds.startAnimation(e, m.animation);
        if (m.sound) |s| t.sound(s, h);
    }

    /// `h`'s behaviour seen as module `M`'s actor; null when `h` has gone or is driven by
    /// another behaviour.
    pub fn actor(t: *Tick, comptime M: type, h: Handle) ?Actor(M) {
        const e = t.world.get(h) orelse return null;
        const tag = comptime behaviours.tagOf(M);
        if (std.meta.activeTag(e.mind) != tag) return null;
        return .{ .tick = t, .handle = h, .entity = e, .kind = t.kindOf(e), .mind = &@field(e.mind, @tagName(tag)) };
    }

    // The hooks: what the systems ask of a behaviour; without the hook, its default.

    /// The player's command, for the entity a player plays (the control system).
    pub fn control(t: *Tick, h: Handle, command: Command) void {
        dispatch(t, h, "control", void, {}, .{command});
    }

    /// The entity's own decisions (the AI system).
    pub fn think(t: *Tick, h: Handle) void {
        dispatch(t, h, "think", void, {}, .{});
    }

    /// A blow meets the entity's body: whether it takes it (by default, yes).
    pub fn struck(t: *Tick, h: Handle, blow: Blow) bool {
        return dispatch(t, h, "struck", bool, true, .{blow});
    }

    /// The entity landed on the ground (the movement system).
    pub fn landed(t: *Tick, h: Handle) void {
        dispatch(t, h, "landed", void, {}, .{});
    }

    /// Whether `by` may grab the entity (by default, no).
    pub fn grabbable(t: *Tick, h: Handle, by: Handle) bool {
        return dispatch(t, h, "grabbable", bool, false, .{by});
    }

    /// The grab began: the entity `holder` holds `held`.
    pub fn grabbed(t: *Tick, holder: Handle, held: Handle) void {
        dispatch(t, holder, "holds", void, {}, .{held});
        dispatch(t, held, "heldBy", void, {}, .{holder});
    }

    /// The item or weapon `item` is picked up by `by`: whether it stays in the world (by
    /// default it goes), and what `by` does with it.
    pub fn pickedUp(t: *Tick, item: Handle, by: Handle) void {
        dispatch(t, by, "picks", void, {}, .{item});
        if (!dispatch(t, item, "pickedUp", bool, false, .{by})) t.world.remove(item);
    }
};

/// Calls hook `hook` of `h`'s behaviour with the actor and `args`; `default` when the entity has
/// gone or its behaviour has no such hook.
fn dispatch(t: *Tick, h: Handle, comptime hook: []const u8, comptime R: type, default: R, args: anytype) R {
    const e = t.world.get(h) orelse return default;
    switch (e.mind) {
        .none => return default,
        inline else => |*m, tag| {
            const M = behaviours.module(tag);
            if (!@hasDecl(M, hook)) return default;
            const a: Actor(M) = .{ .tick = t, .handle = h, .entity = e, .kind = t.kindOf(e), .mind = m };
            return @call(.auto, @field(M, hook), .{a} ++ args);
        },
    }
}

/// An entity seen by its behaviour `M`. A hook that removes its entity returns at once: its
/// fields are then free.
pub fn Actor(comptime M: type) type {
    return struct {
        const Self = @This();

        tick: *Tick,
        handle: Handle,
        entity: *Entity,
        kind: *const Kind,
        mind: *M.Mind,

        /// The behaviour's numbers, as `M.Numbers` types them, from the definition.
        pub fn numbers(a: Self) M.Numbers {
            return kinds_mod.numbersOf(M, a.kind);
        }

        /// Starts the animation `which` from its first frame.
        pub fn animate(a: Self, which: M.Animation) void {
            a.tick.kinds.startAnimation(a.entity, a.kind.animation_of[@intFromEnum(which)]);
        }

        /// Whether the animation `which` plays.
        pub fn playing(a: Self, which: M.Animation) bool {
            return a.entity.animation.index == a.kind.animation_of[@intFromEnum(which)];
        }

        /// Plays the animation `which`, starting it unless it plays already.
        pub fn keepAnimating(a: Self, which: M.Animation) void {
            if (!a.playing(which)) a.animate(which);
        }

        /// Whether the animation has shown all its frames.
        pub fn animationDone(a: Self) bool {
            return a.entity.animation.done;
        }

        /// Starts the move `which`: its animation, its sound.
        pub fn startMove(a: Self, which: M.Move) void {
            a.tick.startMove(a.handle, a.entity, a.kind.move_of[@intFromEnum(which)]);
        }

        pub fn endMove(a: Self) void {
            a.entity.move = null;
        }

        /// Asks for the sound `which` of its definition.
        pub fn sound(a: Self, which: M.Sound) void {
            a.tick.sound(a.kind.sound_of[@intFromEnum(which)], a.handle);
        }

        pub fn draw(a: Self, comptime purpose: random.Purpose) u16 {
            return a.tick.draw(purpose);
        }

        pub fn pick(a: Self, comptime purpose: random.Purpose, comptime n: u16) u16 {
            return a.tick.pick(purpose, n);
        }

        pub fn stop(a: Self) void {
            a.entity.velocity = .zero;
        }

        /// Takes off with `height_speed` (negative: up).
        pub fn leap(a: Self, height_speed: Fixed) void {
            a.entity.velocity.height = height_speed;
            a.entity.flags.airborne = true;
        }

        /// The speed of the blow: across away from its striker, and up, in the air.
        pub fn takePush(a: Self, blow: Blow) void {
            a.entity.velocity = .{ .x = blow.push.x, .height = blow.push.height };
            if (blow.push.height.raw != 0) a.entity.flags.airborne = true;
        }

        /// Faces `target`'s side.
        pub fn faceToward(a: Self, target: *const Entity) void {
            const dx = target.position.x.sub(a.entity.position.x);
            if (dx.raw != 0) a.entity.facing = if (dx.raw < 0) .left else .right;
        }

        /// The nearest entity of `team` other than itself (by the distance across plus the
        /// distance in depth; the first in the pool among equals).
        pub fn nearest(a: Self, team: entity.Team) ?Handle {
            var best: ?Handle = null;
            var best_d: i64 = std.math.maxInt(i64);
            for (&a.tick.world.entities, 0..) |*o, i| {
                if (!o.alive() or o.team != team or i == a.handle.index) continue;
                const d = @as(i64, @abs(o.position.x.sub(a.entity.position.x).raw)) + @abs(o.position.depth.sub(a.entity.position.depth).raw);
                if (d < best_d) {
                    best_d = d;
                    best = a.tick.world.handleAt(i);
                }
            }
            return best;
        }

        pub fn other(a: Self, h: Handle) ?*Entity {
            return a.tick.world.get(h);
        }

        /// The entity goes; the hook returns at once.
        pub fn remove(a: Self) void {
            a.tick.world.remove(a.handle);
        }
    };
}
