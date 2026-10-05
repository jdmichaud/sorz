//! An obstacle of the bridge (round 4's cones, posts and barriers). It stands (`stand`; a barrier
//! solid: the fighters' walks stop at its `solid` box, `Tick.keptOut`) until a player's blow
//! lands on it while it is on the screen, or a thing a player threw meets it there: then it
//! leaves the item the round's script gave it (`Tick.give`), sounds, and is knocked away
//! (`flying`) to the side it flies (its striker's way when it stands), up and across, its
//! animation for that side held; a barrier leaves its top flying too, a piece of its own (`part`)
//! in the items' places, higher, faster. Each falls faster every tick; on the floor it bounces
//! back up at half its speed, its animation running from then; at its second landing it goes.
//! Over a hole it falls on. Left behind the camera, it goes. A blow on it lands (a player's opens
//! the combo's window as on an enemy); a player does not grab it.
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
    /// The kind of the item it holds.
    holds: ?entity.KindId = null,
    /// It was on the screen at its last tick's end: a blow lands on it.
    shown: bool = false,
    /// It is a barrier's top, flying from its first tick.
    part: bool = false,
    /// Its landings since it was knocked away.
    landings: u8 = 0,
    /// It was knocked away at this tick's blows: its flight starts at its next.
    knocked: bool = false,
};

/// Knocked away (its frames face right: to the left, mirrored; a barrier's, either way); a
/// barrier's top.
pub const Animation = enum { stand, fly, part };
pub const Sound = enum { knocked, bounce };

pub const Numbers = struct {
    /// Its height when it stands.
    height: i16,
    /// It stands solid (a barrier).
    solid: u1,
    /// Knocked away: its speed up, and across to the left and to the right (whole pixels a
    /// tick); what each tick adds to its speed down.
    up: Fixed,
    speed_left: Fixed,
    speed_right: Fixed,
    falling: Fixed,
    /// A barrier's top: how much higher it starts, its speed up and across.
    part_above: ?i16 = null,
    part_up: ?Fixed = null,
    part_left: ?Fixed = null,
    part_right: ?Fixed = null,
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
        .start => if (a.mind.part) {
            a.animate(.part);
            a.pause(true);
            a.mind.state = .flying;
        } else {
            a.animate(.stand);
            e.flags.solid = n.solid != 0;
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

/// A tick of its flight: faster down, then its move; on the floor it bounces back up at half
/// its speed, its animation running, and at its second landing it goes. False when it went.
fn fly(a: Actor) bool {
    const e = a.entity;
    e.velocity.height = e.velocity.height.add(a.numbers().falling);
    e.position = e.position.add(e.velocity);
    const floor = a.tick.floorUnder(e.position) orelse return true;
    if (e.position.height.lessThan(floor)) return true;
    e.position.height = .parts(@intCast(floor.whole()), e.position.height.frac());
    a.pause(false);
    a.mind.landings += 1;
    if (a.mind.landings >= 2) {
        a.remove();
        return false;
    }
    e.velocity.height = .{ .raw = (-%e.velocity.height.raw) >> 1 };
    a.sound(.bounce);
    return true;
}

/// A blow or a thing thrown that meets it, standing on the screen, knocks it away to the side
/// its striker faces: the blow lands.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (a.mind.state != .stand or !a.mind.shown) return false;
    const by = a.other(blow.attacker) orelse return false;
    const n = a.numbers();
    const e = a.entity;
    const right = if (e.velocity.x.raw != 0) e.velocity.x.raw > 0 else !by.facingLeft();
    e.flags.solid = false;
    if (a.mind.holds) |item| {
        a.mind.holds = null;
        breakable.leave(a.tick, item, e.position);
    }
    a.sound(.knocked);
    e.velocity.height = .parts(@intCast(n.up.whole()), e.velocity.height.frac());
    e.velocity.x = .parts(@intCast((if (right) n.speed_right else n.speed_left).whole()), e.velocity.x.frac());
    if (n.part_above == null) e.facing = if (right) .right else .left;
    a.animate(.fly);
    a.pause(true);
    a.mind.state = .flying;
    a.mind.knocked = true;
    if (n.part_above) |above| part(a, above, right);
    return true;
}

/// A barrier's top flies off from it, higher, in the items' first free place (none: none).
fn part(a: Actor, above: i16, right: bool) void {
    const n = a.numbers();
    const e = a.entity;
    const w = a.tick.world;
    const places = @TypeOf(w.*).item_places;
    const at: fixed.Vec3 = .{ .x = .pixels(e.position.x.whole()), .depth = .pixels(e.position.depth.whole()), .height = .pixels(e.position.height.whole() + above) };
    const h = w.spawnWithin(a.tick.kinds, e.kind.?, places.from, places.to, at, .right) catch return;
    const p = w.get(h).?;
    p.mind.obstacle_r4.part = true;
    p.velocity.height = .pixels((n.part_up orelse Fixed.zero).whole());
    p.velocity.x = .pixels((if (right) n.part_right orelse Fixed.zero else n.part_left orelse Fixed.zero).whole());
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

/// Taken up from a situation in its state: standing (a barrier solid); flying, in its
/// animation (the traces do not tell its side).
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    const n = a.numbers();
    switch (a.mind.state) {
        .start => {},
        .stand => {
            a.animate(.stand);
            a.entity.flags.solid = n.solid != 0;
        },
        .flying => a.animate(if (a.mind.part) .part else .fly),
    }
    const from_camera = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}
