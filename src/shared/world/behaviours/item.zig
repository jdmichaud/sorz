//! An item a player picks up: the food (the apple, the beef), a life, a special attack, the money
//! bag, the gold bar. It falls to the ground at its speed (`falling`) and lies there (`lying`).
//! Picked up (the player's pick-up, `Tick.pickedUp`), it gives the one who picked it what its
//! definition says (health up to the most, a life, a special attack, points), with its sound,
//! and goes. Left behind the camera, it goes.
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { start, falling, lying };

pub const Mind = struct {
    state: State = .start,
};

pub const Animation = enum { lying };
pub const Sound = enum { picked };

pub const Numbers = struct {
    /// Its speed down, falling.
    fall: Fixed,
    /// It goes this far behind the camera's place across.
    left_behind: i16,
    /// What it gives: health (up to the most), lives, special attacks, points.
    health_most: i16,
    health: i16,
    lives: u8,
    specials: u8,
    points: u32,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    e.flags.still = true;
    switch (a.mind.state) {
        .start => {
            a.animate(.lying);
            e.flags.in_front = a.tick.thingsInFront();
            a.mind.state = .falling;
        },
        .falling => if (e.position.height.whole() >= a.tick.world.ground.whole()) {
            a.mind.state = .lying;
        } else {
            e.velocity.height = .parts(@intCast(a.numbers().fall.whole()), e.velocity.height.frac());
            e.position = e.position.add(e.velocity);
        },
        .lying => {},
    }
    if (a.tick.behindCamera(e.position.x, a.numbers().left_behind)) a.remove();
}

/// Taken up from a situation in its state: its pose.
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    a.animate(.lying);
}

/// Picked up by `by`: it gives what it gives, and goes.
pub fn pickedUp(a: Actor, by: Handle) bool {
    const n = a.numbers();
    a.sound(.picked);
    const w = a.tick.world;
    if (w.get(by)) |e| if (n.health != 0) {
        const h = e.health + n.health;
        e.health = if (h < 0) 0 else @min(h, n.health_most);
    };
    if (w.playerOf(by)) |k| {
        const p = &w.players[k];
        p.lives +|= n.lives;
        p.specials +|= n.specials;
    }
    if (n.points != 0) a.tick.score(by, n.points);
    return false;
}
