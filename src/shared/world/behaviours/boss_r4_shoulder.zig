//! Round 4's boss's shoulder (boss_r4.zig): his rush's blow, at his shoulder through it. Its
//! first look (`lead`) runs to the last tick of its frame `turn_frame`, then its second
//! (`shoulder`); in its second it goes once he leaves his charge. A blow that lands knocks the
//! player down, its damage his power. Its numbers, animations and move are its definition's
//! (`entities/boss_r4_shoulder.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const entity = @import("../entity.zig");

const Handle = entity.Handle;
const Entity = entity.Entity;
const Actor = tick.Actor(@This());

pub const State = enum { lead, shoulder };

/// The traces' names of its states (the original's object numbers them).
pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .lead },
    .{ .name = "s1", .state = .shoulder },
};

pub const Mind = struct {
    state: State = .lead,
    /// The boss whose shoulder it is.
    boss: ?Handle = null,
};

pub const Animation = enum { lead, shoulder };
pub const Move = enum { shoulder };

pub const Numbers = struct {
    /// Its second look at its first's frame `turn_frame`, with `turn_left` ticks left.
    turn_left: u8,
    turn_frame: u8,
    /// At his shoulder: `ahead` the way he faces, `deeper` in depth, `above` his feet
    /// (`above_low` at his frames 0 and `low_frame`).
    ahead: i16,
    deeper: i16,
    above: i16,
    above_low: i16,
    low_frame: u8,
};

/// Made by the boss `by` (`b`) as he rushes: its blow his power, its first look, at his shoulder
/// at once.
pub fn start(a: Actor, by: Handle, power: u8, b: *const Entity) void {
    a.mind.boss = by;
    a.entity.power = power;
    a.startMove(.shoulder);
    place(a, b);
}

pub fn think(a: Actor) void {
    const n = a.numbers();
    a.entity.flags.still = true;
    const b = a.other(a.mind.boss orelse return a.remove()) orelse return a.remove();
    switch (a.mind.state) {
        .lead => if (a.ticksLeft() == n.turn_left and a.frame() == n.turn_frame) {
            a.mind.state = .shoulder;
            a.animate(.shoulder);
        },
        .shoulder => {
            const charging = switch (b.mind) {
                .boss_r4 => |m| m.state == .swing,
                else => false,
            };
            if (!charging) return a.remove();
        },
    }
    place(a, b);
}

/// At the boss `b`'s shoulder, facing as he faces: his whole pixels' place (its own fractions
/// kept), ahead, deeper, above his feet.
pub fn place(a: Actor, b: *const Entity) void {
    const n = a.numbers();
    const e = a.entity;
    if (e.facing != b.facing) {
        e.facing = b.facing;
        a.showBoxes();
    }
    const ahead: i32 = if (b.facing == .left) -@as(i32, n.ahead) else n.ahead;
    e.position.x = .parts(@intCast(b.position.x.whole() + ahead), e.position.x.frac());
    e.position.depth = .parts(@intCast(b.position.depth.whole() + n.deeper), e.position.depth.frac());
    const f = b.animation.frame;
    const up = if (f == 0 or f == n.low_frame) n.above_low else n.above;
    e.position.height = .parts(@intCast(b.position.height.whole() - up), e.position.height.frac());
}
