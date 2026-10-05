//! Round 2's boss's trail (boss_r2.zig): as he dodges and dashes, a still copy of his look where
//! he is, for a few ticks (fewer for twins, or with two players). Its numbers and animations
//! are its definition's (`entities/boss_r2_trail.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const entity = @import("../entity.zig");

const Entity = entity.Entity;
const Actor = tick.Actor(@This());

pub const State = enum { fade };

/// The traces' name of its state (the original's object has the one).
pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .fade },
};

pub const Mind = struct {
    state: State = .fade,
    /// Its ticks left.
    left: u8 = 0,
};

/// The boss's looks it copies: his walk, his slash.
pub const Animation = enum { stand, swing };

pub const Numbers = struct {
    ticks_twins: u8,
    ticks_two: u8,
    ticks: u8,
};

/// A copy of the boss `b` (his look, his frame, his whole pixels), still, for its ticks.
pub fn copy(a: Actor, b: *const Entity, twins: bool, two_players: bool) void {
    const n = a.numbers();
    const e = a.entity;
    e.flags.still = true;
    e.facing = b.facing;
    const slashing = switch (b.mind) {
        .boss_r2 => |m| m.state == .swing,
        else => false,
    };
    a.animate(if (slashing) .swing else .stand);
    a.setFrame(b.animation.frame);
    a.pause(true);
    e.position = .{
        .x = .pixels(b.position.x.whole()),
        .depth = .pixels(b.position.depth.whole()),
        .height = .pixels(b.position.height.whole()),
    };
    a.mind.left = if (twins) n.ticks_twins else if (two_players) n.ticks_two else n.ticks;
}

pub fn think(a: Actor) void {
    a.mind.left -%= 1;
    if (a.mind.left == 0) a.remove();
}
