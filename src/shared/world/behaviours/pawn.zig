//! A pawn (synthetic, behaviours.zig): the player of the world's tests. It walks with the pad's
//! directions, strikes with B, jumps with C (keeping its walk's speed across), and reels a while
//! when struck. Its numbers, animations and strike are its definition's.
const tick = @import("../tick.zig");
const Fixed = @import("../fixed.zig").Fixed;
const Vec3 = @import("../fixed.zig").Vec3;
const Command = @import("../world.zig").Command;

const Actor = tick.Actor(@This());

pub const State = enum { stand, walk, attack, jump, hurt };

pub const Mind = struct {
    state: State = .stand,
    /// Logic ticks in the state.
    ticks: u16 = 0,
};

pub const Animation = enum { stand, walk, attack, jump, hurt };
pub const Move = enum { attack };

pub const Numbers = struct {
    /// Its walk across and in depth, and its jump's speed up, a logic tick.
    walk_x: Fixed,
    walk_depth: Fixed,
    jump: Fixed,
    /// The ticks it reels when struck.
    hurt: u16,
};

fn enter(a: Actor, state: State) void {
    a.mind.state = state;
    a.mind.ticks = 0;
}

pub fn control(a: Actor, c: Command) void {
    const n = a.numbers();
    a.mind.ticks +|= 1;
    switch (a.mind.state) {
        .stand, .walk => {
            if (c.pressed.b) {
                a.stop();
                enter(a, .attack);
                a.startMove(.attack);
                return;
            }
            if (c.pressed.c) {
                enter(a, .jump);
                a.animate(.jump);
                a.leap(n.jump.neg());
                return;
            }
            var v: Vec3 = .zero;
            if (c.held.left) v.x = n.walk_x.neg() else if (c.held.right) v.x = n.walk_x;
            if (c.held.up) v.depth = n.walk_depth.neg() else if (c.held.down) v.depth = n.walk_depth;
            a.entity.velocity = v;
            if (v.x.raw != 0) a.entity.facing = if (v.x.raw < 0) .left else .right;
            const moving = !v.eql(.zero);
            const state: State = if (moving) .walk else .stand;
            if (state != a.mind.state) enter(a, state);
            a.keepAnimating(if (moving) .walk else .stand);
        },
        .attack => if (a.animationDone()) {
            a.endMove();
            enter(a, .stand);
            a.animate(.stand);
        },
        .jump => {},
        .hurt => if (a.mind.ticks >= n.hurt) {
            enter(a, .stand);
            a.animate(.stand);
        },
    }
}

pub fn landed(a: Actor) void {
    if (a.mind.state != .jump) return;
    a.stop();
    enter(a, .stand);
    a.animate(.stand);
}

pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (a.mind.state == .hurt) return false;
    a.takeDamage(blow.attacker, blow.damage);
    a.endMove();
    a.stop();
    enter(a, .hurt);
    a.animate(.hurt);
    return true;
}
