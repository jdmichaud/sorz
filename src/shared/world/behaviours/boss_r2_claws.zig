//! Round 2's boss's claws (boss_r2.zig): a look that follows him through his slash, at his
//! place (a little nearer the screen in depth), shown at his slash's frames that strike, each
//! strike's first with a swish; gone once he leaves his slash. No blow of its own: his slash's
//! frames strike. Its numbers, animations and sound are its definition's
//! (`entities/boss_r2_claws.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");

const Handle = entity.Handle;
const Entity = entity.Entity;
const Actor = tick.Actor(@This());

pub const State = enum { follow };

/// The traces' name of its state (the original's object has the one).
pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .follow },
};

pub const Mind = struct {
    state: State = .follow,
    /// The boss it follows.
    boss: ?Handle = null,
};

/// The first strike's look and the second's.
pub const Animation = enum { claws, claws_2 };
pub const Sound = enum { swish };

pub const Numbers = struct {
    /// The boss's frames it shows at (the latter excluded), the first strike's and the second's.
    first_from: u8,
    first_to: u8,
    second_from: u8,
    second_to: u8,
    /// Nearer the screen than the boss, in depth.
    below: i16,
    /// The tick of the boss's frame (its ticks left) the swish comes at.
    swish_tick: u8,
};

pub fn think(a: Actor) void {
    a.entity.flags.still = true;
    const b = a.other(a.mind.boss orelse return a.remove()) orelse return a.remove();
    const slashing = switch (b.mind) {
        .boss_r2 => |m| m.state == .swing,
        else => false,
    };
    if (!slashing) return a.remove();
    place(a, b);
}

/// At the boss `b`: hidden but at its frames that strike, shown then in the strike's look, the
/// other way from the boss (the original's claws' looks face the other way from his frames'); its
/// place the boss's whole pixels (its own fractions kept), a little nearer in depth; a swish at
/// each strike's first frame, its second tick.
pub fn place(a: Actor, b: *const Entity) void {
    const n = a.numbers();
    const e = a.entity;
    const f = b.animation.frame;
    e.flags.hidden = true;
    if (f >= n.first_from and f < n.first_to) {
        show(a, .claws, b);
    } else if (f >= n.second_from and f < n.second_to) {
        show(a, .claws_2, b);
    }
    e.position.x = .parts(@intCast(b.position.x.whole()), e.position.x.frac());
    e.position.depth = .parts(@intCast(b.position.depth.whole() + n.below), e.position.depth.frac());
    e.position.height = .parts(@intCast(b.position.height.whole()), e.position.height.frac());
    if ((f == n.first_from or f == n.second_from) and b.animation.left == n.swish_tick) a.sound(.swish);
}

fn show(a: Actor, which: Animation, b: *const Entity) void {
    a.entity.flags.hidden = false;
    a.entity.facing = b.facing.turned();
    if (!a.plays(which)) a.animate(which);
    a.pause(true);
}
