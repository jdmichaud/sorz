//! The knife: a weapon (weapon.zig's body and states) that its holder can also throw. Thrown
//! (`Tick.throwWeapon`), it leaves its holder's hand ahead of it and below, and flies straight
//! across at its speed (`flying`), a thing thrown: its blow is its power and knocks down, on the
//! enemies when a player threw it, on the players when an enemy did. It is gone (`gone`, then out
//! of the world at its next tick) when its blow lands or a blow meets it; out of the screen's
//! sides, it is out of the world at once. Where the round's floor stops it (`stopped`: a wall's
//! cell, round 7's lift) it bounces (`bouncing`): a thing thrown no more, it goes back at a
//! quarter of its speed, falling, and once down on the round's ground it lies worn out, to blink
//! out. Its numbers and its poses are its definition's (`entities/knife.json`).
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
    /// Gone at an earlier tick (else at this one's blows).
    went: bool = false,
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
        .gone => {
            if (a.mind.went) return a.remove();
            a.mind.went = true;
            return;
        },
        .bouncing => return bouncing(a),
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

/// It flies across while on the screen's sides; else it is out of the world at once.
fn fly(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    e.flags.still = true;
    const from_camera = e.position.x.whole() - a.tick.world.camera.x.whole();
    if (from_camera < n.flight_from or from_camera >= n.flight_to) return a.remove();
    if (stopped(a)) {
        // Back at a quarter of its speed, from its next tick, a thing thrown no more.
        e.velocity.x = .{ .raw = -%e.velocity.x.raw >> n.bounce_shift };
        e.missile = null;
        a.mind.state = .bouncing;
        return;
    }
    e.position = e.position.add(e.velocity);
}

/// Whether the round's floor stops it where it is: the cell there has a floor at its height or
/// above (a wall's cell has one everywhere), as the original's cell attribute answers (its
/// height taken from 0 down).
fn stopped(a: Actor) bool {
    const e = a.entity;
    const c = a.tick.cellAt(e.position) orelse return false;
    return c.floor and @max(e.position.height.whole(), 0) >= c.height;
}

/// Bouncing off a wall: it falls, faster each tick, and moves; stopped where it is now (a cell's
/// floor, a wall's), when it is below the round's ground (its height compared unsigned, as the
/// original's word), it lies on the ground (the fraction of its height and its speeds kept), worn
/// out (its pick-ups at their end), as it showed.
fn bouncing(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    e.flags.still = true;
    e.velocity.height = e.velocity.height.add(n.bounce_gravity);
    e.position = e.position.add(e.velocity);
    if (!stopped(a)) return;
    const ground = a.tick.world.ground.whole();
    const z: u16 = @bitCast(@as(i16, @truncate(e.position.height.whole())));
    if (ground >= z) return;
    e.position.height = .parts(@intCast(ground), e.position.height.frac());
    a.mind.body.taken = n.uses;
    a.mind.state = .lying;
}

fn gone(a: Actor) void {
    a.entity.missile = null;
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

pub fn putDown(a: Actor) void {
    C.putDown(a);
}

pub fn pickedUp(a: Actor, by: Handle) bool {
    return C.pickedUp(a, by);
}

pub fn heldLastBy(a: Actor) ?Handle {
    return C.heldLastBy(a);
}

pub fn takeable(a: Actor) bool {
    return C.takeable(a);
}

pub fn takeUp(a: Actor, elapsed: u32) void {
    C.takeUp(a, elapsed);
    if (a.mind.state == .flying) C.pose(a, "level");
    if (a.mind.state == .gone) a.mind.went = elapsed >= 1;
}

pub fn takeUpTaken(a: Actor, times: u8) void {
    a.mind.body.taken = times;
}
