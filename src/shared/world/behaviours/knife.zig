//! The knife: a weapon (weapon.zig's body and states) that its holder can also throw. Thrown
//! (`Tick.throwWeapon`), it leaves its holder's hand ahead of it and below, and flies straight
//! across at its speed (`flying`), a thing thrown: its blow is its power and knocks down, on the
//! enemies when a player threw it, on the players when an enemy did. It is gone (`gone`, then out
//! of the world at its next tick) when its blow lands, when a blow meets it, or when it leaves the
//! screen's sides. Its numbers and its poses are its definition's (`entities/knife.json`).
//!
//! TODO(PLAN item 15): its bounce off a wall (`bouncing`: a quarter of its speed back, falling,
//! worn out once down) waits for the round's floor, whose cells say where the walls are.
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const weapon = @import("weapon.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());
const C = weapon.Of(@This());

pub const State = enum { start, lying, falling, flying, held, blinking_out, bouncing, gone };

pub const Mind = struct {
    state: State = .start,
    body: weapon.Body = .{},
    /// Its holder threw it: it flies from its next turn.
    thrown: bool = false,
};

pub const Numbers = struct {
    power: u8,
    uses: u8,
    blink: u8,
    drop: Fixed,
    left_behind: i16,
    /// Thrown: its speed across, how far ahead of its holder's hand and below it it starts;
    /// across from the camera's place, the sides it flies within (the latter excluded).
    throw_speed: Fixed,
    throw_ahead: i16,
    throw_below: i16,
    flight_from: i16,
    flight_to: i16,
    bounce_shift: u4,
    bounce_gravity: Fixed,
};

pub fn think(a: Actor) void {
    switch (a.mind.state) {
        .held => if (a.mind.thrown) return flies(a),
        .flying => return fly(a),
        .gone => return a.remove(),
        .bouncing => {},
        else => {},
    }
    if (C.act(a)) _ = C.leftBehind(a);
}

/// Thrown from its holder's hand: ahead of it and below, flying the way its holder faces, a
/// thing thrown with its power, out of its holder's hand.
fn flies(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    const by = e.holder orelse return;
    const holder = a.other(by) orelse return;
    const way: i32 = holder.facing.sign();
    a.mind.thrown = false;
    e.holder = null;
    e.flags.hidden = false;
    e.facing = holder.facing;
    e.position.x = e.position.x.add(.pixels(n.throw_ahead * way));
    e.position.height = e.position.height.add(.pixels(n.throw_below));
    e.velocity = .{ .x = n.throw_speed.times(way) };
    e.missile = .{ .by = by, .damage = n.power };
    C.pose(a, "level");
    a.mind.state = .flying;
}

/// It flies across while on the screen's sides; else it is gone.
fn fly(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    e.flags.still = true;
    const from_camera = e.position.x.whole() - a.tick.world.camera.x.whole();
    if (from_camera < n.flight_from or from_camera >= n.flight_to) return gone(a);
    e.position = e.position.add(e.velocity);
}

fn gone(a: Actor) void {
    a.entity.missile = null;
    a.entity.velocity = .zero;
    a.mind.state = .gone;
}

/// Its holder threw it.
pub fn hurled(a: Actor) void {
    a.mind.thrown = true;
}

/// Its blow landed: it is gone.
pub fn blowLanded(a: Actor, target: Handle) void {
    _ = target;
    if (a.mind.state == .flying) gone(a);
}

/// A blow meets it flying: it is gone (the blow lands).
pub fn struck(a: Actor, blow: tick.Blow) bool {
    _ = blow;
    if (a.mind.state != .flying) return false;
    gone(a);
    return true;
}

pub fn follow(a: Actor) void {
    C.follow(a);
}

pub fn dropped(a: Actor) void {
    C.dropped(a);
}

pub fn takeUp(a: Actor, elapsed: u32) void {
    C.takeUp(a, elapsed);
    if (a.mind.state == .flying) C.pose(a, "level");
}

pub fn takeUpTaken(a: Actor, times: u8) void {
    a.mind.body.taken = times;
}
