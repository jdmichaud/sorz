//! A sparring partner (synthetic, behaviours.zig): it stands a while, closes in on the nearest
//! player, punches when the player is in reach, reels from a blow, is knocked down by a strong
//! one or by its last health, and goes some time after it is knocked out. Its numbers, its
//! animations, its punch and its sound are its definition's.
const tick = @import("../tick.zig");
const Fixed = @import("../fixed.zig").Fixed;

const Actor = tick.Actor(@This());

pub const State = enum { stand, approach, punch, reel, knocked_down, knocked_out };

pub const Mind = struct {
    state: State = .stand,
    /// Logic ticks in the state.
    ticks: u16 = 0,
    /// The ticks it stands this time before it closes in.
    wait: u16 = 0,
};

pub const Animation = enum { stand, walk, punch, reel, down };
pub const Move = enum { punch };
pub const Sound = enum { hurt };

pub const Numbers = struct {
    /// Its walk, across and in depth, a logic tick.
    walk_speed: Fixed,
    /// How far across a player may be for its punch, in pixels; in depth, `depth_reach`.
    reach: i16,
    depth_reach: i16,
    /// The ticks it stands at least; up to 15 more are drawn each time.
    wait: u16,
    /// The ticks it reels, and lies knocked out before it goes.
    reel: u16,
    knocked_out: u16,
};

fn enter(a: Actor, state: State) void {
    a.mind.state = state;
    a.mind.ticks = 0;
}

fn standStill(a: Actor) void {
    a.stop();
    enter(a, .stand);
    a.animate(.stand);
}

pub fn think(a: Actor) void {
    const n = a.numbers();
    a.mind.ticks +|= 1;
    switch (a.mind.state) {
        .stand => {
            if (a.mind.ticks == 1) a.mind.wait = n.wait + a.pick(.sparring_wait, 16);
            if (a.mind.ticks >= a.mind.wait) {
                enter(a, .approach);
                a.animate(.walk);
            }
        },
        .approach => {
            const target = a.nearest(.player) orelse return standStill(a);
            const t = a.other(target).?;
            a.faceToward(t);
            const dx = t.position.x.sub(a.entity.position.x).whole();
            const dd = t.position.depth.sub(a.entity.position.depth).whole();
            const across = @abs(dx) > n.reach;
            const deep = @abs(dd) > n.depth_reach;
            if (!across and !deep) {
                a.stop();
                enter(a, .punch);
                a.startMove(.punch);
                return;
            }
            a.entity.velocity.x = if (across) n.walk_speed.times(if (dx < 0) -1 else 1) else .zero;
            a.entity.velocity.depth = if (deep) n.walk_speed.times(if (dd < 0) -1 else 1) else .zero;
        },
        .punch => if (a.animationDone()) {
            a.endMove();
            standStill(a);
        },
        .reel => if (a.mind.ticks >= n.reel) standStill(a),
        .knocked_down => {},
        .knocked_out => if (a.mind.ticks >= n.knocked_out) a.remove(),
    }
}

pub fn struck(a: Actor, blow: tick.Blow) bool {
    switch (a.mind.state) {
        .reel, .knocked_down, .knocked_out => return false,
        else => {},
    }
    a.endMove();
    a.sound(.hurt);
    if (blow.reaction == .knock_down or a.entity.health <= blow.damage) {
        enter(a, .knocked_down);
        a.animate(.down);
        a.takePush(blow);
        a.entity.flags.airborne = true;
    } else {
        a.stop();
        enter(a, .reel);
        a.animate(.reel);
    }
    return true;
}

pub fn landed(a: Actor) void {
    if (a.mind.state != .knocked_down) return;
    a.stop();
    if (a.entity.health <= 0) enter(a, .knocked_out) else standStill(a);
}
