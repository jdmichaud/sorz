//! A thing of the street a blow knocks away (round 2's oil drums). It stands solid (`stand`: the
//! fighters' walks stop at its `solid` box, `Tick.keptOut`) until a player's blow lands on it
//! while it is on the screen, or a thing a player threw meets it there: then it leaves the item
//! the round's script gave it (`Tick.give`), sounds, and flies off (`flying`) to the side the one
//! that struck it faces, up and down again, bouncing off the ground, and goes after its flight's
//! ticks. A blow on it lands (a player's opens the combo's window as on an enemy); a player does
//! not grab it. Left behind the camera, it goes.
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
    /// The ticks left of its flight.
    timer: u8 = 0,
    /// The kind of the item it holds.
    holds: ?entity.KindId = null,
    /// It was on the screen at its last tick's end: a blow lands on it.
    shown: bool = false,
    /// It was knocked away at this tick's blows: its flight counts from its next.
    knocked: bool = false,
};

/// Flying, facing the way it flies (the frames face right).
pub const Animation = enum { stand, fly };
pub const Sound = enum { knocked };

pub const Numbers = struct {
    /// Its height when it stands.
    height: i16,
    /// The ticks of its flight, and its speed across and up as it starts.
    flight: u8,
    speed: Fixed,
    up: Fixed,
    /// Added to its speed down each tick: going up, coming down.
    rising: Fixed,
    falling: Fixed,
    /// Its speed down as it meets the ground (up: negative).
    bounce: Fixed,
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
            e.flags.solid = true;
            e.position.height = .parts(n.height, e.position.height.frac());
            a.mind.state = .stand;
        },
        .stand => {},
        .flying => if (a.mind.knocked) {
            a.mind.knocked = false;
        } else {
            a.mind.timer -%= 1;
            if (a.mind.timer == 0) return a.remove();
            e.velocity.height = e.velocity.height.add(if (e.velocity.height.raw < 0) n.rising else n.falling);
            e.position = e.position.add(e.velocity);
            if (a.atGround()) e.velocity.height = n.bounce;
        },
    }
    const from_camera = e.position.x.whole() - a.tick.world.camera.x.whole();
    if (from_camera <= -n.left_behind) return a.remove();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
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
    e.facing = by.facing;
    e.velocity.x = .parts(@intCast(n.speed.whole() * e.facing.sign()), e.velocity.x.frac());
    e.velocity.height = .parts(@intCast(n.up.whole()), e.velocity.height.frac());
    a.animate(.fly);
    a.mind.timer = n.flight;
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

/// Taken up from a situation in its state: standing, solid; flying, its ticks gone down.
pub fn takeUp(a: Actor, elapsed: u32) void {
    const n = a.numbers();
    switch (a.mind.state) {
        .start => {},
        .stand => {
            a.animate(.stand);
            a.entity.flags.solid = true;
        },
        .flying => {
            a.animate(.fly);
            const gone: u8 = @intCast(@min(elapsed, 255));
            a.mind.timer = @max(n.flight -| gone, 1);
        },
    }
    const from_camera = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}
