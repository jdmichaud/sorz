//! A thing on the deck a blow knocks away (round 5's, type $1F). It stands solid (`stand`: the
//! fighters' walks stop at its `solid` box, `Tick.keptOut`), in front of the layers' cells, until
//! a player's blow lands on it while it is on the screen, or a thing a player threw meets it
//! there: then it leaves the item the round's script gave it (`Tick.give`), sounds, and flies off
//! (`flying`) to the side the one that struck it faces, up and down again; at each meeting with
//! the ground it bounces back up half as fast, with its sound, and at its last it goes. A blow on
//! it lands (a player's opens the combo's window as on an enemy); a player does not grab it.
//! Left behind the camera, it goes.
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const breakable = @import("breakable.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { start, stand, flying };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .stand },
    .{ .name = "s2", .state = .flying },
};

pub const Mind = struct {
    state: State = .start,
    /// Its meetings with the ground in its flight.
    bounces: u8 = 0,
    /// The kind of the item it holds.
    holds: ?entity.KindId = null,
    /// It was on the screen at its last tick's end: a blow lands on it.
    shown: bool = false,
    /// It was knocked away at this tick's blows: its flight starts at its next.
    knocked: bool = false,
};

/// Its stand; its flight, whichever way it flies.
pub const Animation = enum { stand, fly };
pub const Sound = enum { knocked, bounce };

pub const Numbers = struct {
    /// Its height when it stands.
    height: i16,
    /// Its speed across (whole pixels, to the side it flies) and up (whole pixels, negative)
    /// as it starts; added to its speed down each tick of its flight.
    speed: Fixed,
    up: Fixed,
    falling: Fixed,
    /// Its meetings with the ground: at the last it goes.
    bounces: u8,
    /// It goes this far behind the camera's place across.
    left_behind: i16,
    /// On the screen: its place across less the camera's from `screen_from` up to `screen_to`
    /// (excluded).
    screen_from: i16,
    screen_to: i16,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    e.flags.still = true;
    const n = a.numbers();
    switch (a.mind.state) {
        .start => {
            a.animate(.stand);
            e.flags.in_front = true;
            e.flags.solid = true;
            e.position.height = .parts(n.height, e.position.height.frac());
            a.mind.state = .stand;
        },
        .stand => {},
        .flying => if (a.mind.knocked) {
            a.mind.knocked = false;
        } else if (!fly(a)) return,
    }
    const from_camera = e.position.x.whole() - a.tick.world.camera.x.whole();
    if (from_camera <= -n.left_behind) return a.remove();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}

/// A tick of its flight: down on the ground, it bounces back up half as fast, or goes at its last
/// bounce (false).
fn fly(a: Actor) bool {
    const n = a.numbers();
    const e = a.entity;
    e.velocity.height = e.velocity.height.add(n.falling);
    e.position = e.position.add(e.velocity);
    if (!a.atGround()) return true;
    e.position.height = .parts(@intCast(a.tick.world.ground.whole()), e.position.height.frac());
    a.mind.bounces += 1;
    if (a.mind.bounces >= n.bounces) {
        a.remove();
        return false;
    }
    e.velocity.height = .{ .raw = (-e.velocity.height.raw) >> 1 };
    a.sound(.bounce);
    return true;
}

/// A blow or a thing thrown that meets it, standing on the screen, knocks it away, to the side
/// that faces: the blow lands.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (a.mind.state != .stand or !a.mind.shown) return false;
    const by = a.other(blow.attacker) orelse return false;
    const n = a.numbers();
    const e = a.entity;
    e.flags.solid = false;
    if (a.mind.holds) |item| {
        a.mind.holds = null;
        breakable.leave(a.tick, item, e.position);
    }
    e.velocity.x = .parts(@intCast(n.speed.whole() * by.facing.sign()), e.velocity.x.frac());
    e.velocity.height = .parts(@intCast(n.up.whole()), e.velocity.height.frac());
    a.animate(.fly);
    a.mind.state = .flying;
    a.mind.knocked = true;
    a.sound(.knocked);
    return true;
}

/// A player does not hold it.
pub fn grabbable(a: Actor, by: Handle) bool {
    _ = a;
    _ = by;
    return false;
}

/// The round's script gives it its item.
pub fn given(a: Actor, item: entity.KindId) void {
    a.mind.holds = item;
}

/// Taken up from a situation in its state: standing, solid, in front; flying, as it flies (its
/// bounces are not in the traces).
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    const n = a.numbers();
    a.entity.flags.in_front = true;
    switch (a.mind.state) {
        .start => {},
        .stand => {
            a.animate(.stand);
            a.entity.flags.solid = true;
        },
        .flying => a.animate(.fly),
    }
    const from_camera = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}
