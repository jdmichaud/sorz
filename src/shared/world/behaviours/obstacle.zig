//! A thing on the way a blow knocks away: round 4's cones, posts and barriers on the bridge,
//! round 5's things on the deck. It stands (`stand`; solid when its definition says so: the
//! fighters' walks stop at its `solid` box, `Tick.keptOut`; in front of the layers' cells when
//! it says so) until a player's blow lands on it while it is on the screen, or a thing a player
//! threw meets it there: then it leaves the item the round's script gave it (`Tick.give`),
//! sounds, and is knocked away (`flying`) up and across, to the side it already moves to, else
//! the one its striker faces; facing that side when its flight's look is drawn for one, its
//! look held until it first meets the floor when its definition says so. A barrier sends its top
//! flying too, a thing of its own kind (`<its name>_top`) in the items' places, higher. Each falls
//! faster every tick; on the floor it bounces back up at half its speed, its look running, and
//! at its last meeting with the floor it goes. Over a hole it falls on. Left behind the camera,
//! it goes. A blow on it lands (a player's opens the combo's window as on an enemy); a player
//! does not grab it.
//!
//! The other program's traces name its states by number (`trace_states`).
const std = @import("std");
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
    /// Its meetings with the floor since it was knocked away.
    landings: u8 = 0,
    /// It was knocked away at this tick: its flight starts at its next.
    knocked: bool = false,
};

/// Its stand; its flight (facing right when it turns to its side).
pub const Animation = enum { stand, fly };
pub const Sound = enum { knocked, bounce };

pub const Numbers = struct {
    /// Its height when it stands; standing, it is solid (1 or 0), it is drawn in front of the
    /// layers' cells (1; none or 0: as the round's script placed it).
    height: i16,
    solid: u1,
    in_front: ?u1 = null,
    /// Knocked away: its speed up, and across to the left and to the right (whole pixels a
    /// tick); what each tick adds to its speed down; its meetings with the floor, the last of
    /// which it goes at.
    up: Fixed,
    speed_left: Fixed,
    speed_right: Fixed,
    falling: Fixed,
    bounces: u8,
    /// Its flight's look faces the side it flies to (1), and is held until it first meets the
    /// floor (1).
    turns: u1,
    held: u1,
    /// A barrier: its top (`<its name>_top`) flies off from this much higher.
    top_above: ?i16 = null,
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
            e.flags.solid = n.solid != 0;
            if ((n.in_front orelse 0) != 0) e.flags.in_front = true;
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
/// its speed, its look running, and at its last meeting with the floor it goes. False when it
/// went.
fn fly(a: Actor) bool {
    const n = a.numbers();
    const e = a.entity;
    e.velocity.height = e.velocity.height.add(n.falling);
    e.position = e.position.add(e.velocity);
    const floor = a.tick.floorUnder(e.position) orelse return true;
    if (e.position.height.lessThan(floor)) return true;
    e.position.height = .parts(@intCast(floor.whole()), e.position.height.frac());
    a.pause(false);
    a.mind.landings += 1;
    if (a.mind.landings >= n.bounces) {
        a.remove();
        return false;
    }
    e.velocity.height = .{ .raw = (-%e.velocity.height.raw) >> 1 };
    a.sound(.bounce);
    return true;
}

/// A blow or a thing thrown that meets it, standing on the screen, knocks it away: to the side
/// it moves to, else the one its striker faces. The blow lands.
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
    knock(a, right);
    if (n.top_above) |above| top(a, above, right);
    return true;
}

/// Knocked away to the right or the left: its speeds' whole pixels (their fractions kept), its
/// flight's look (facing its side when it turns, held when it is), from its next tick.
fn knock(a: Actor, right: bool) void {
    const n = a.numbers();
    const e = a.entity;
    e.velocity.height = .parts(@intCast(n.up.whole()), e.velocity.height.frac());
    e.velocity.x = .parts(@intCast((if (right) n.speed_right else n.speed_left).whole()), e.velocity.x.frac());
    if (n.turns != 0) e.facing = if (right) .right else .left;
    a.animate(.fly);
    a.pause(n.held != 0);
    a.mind.state = .flying;
    a.mind.knocked = true;
}

/// A barrier's top, a thing of its own kind, flies off from it, higher, in the items' first
/// free place (none: none).
fn top(a: Actor, above: i16, right: bool) void {
    const e = a.entity;
    const w = a.tick.world;
    var buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&buf, "{s}_top", .{a.kind.definition.name}) catch return;
    const kind = a.tick.kinds.find(name) orelse return;
    const places = @TypeOf(w.*).item_places;
    const at: fixed.Vec3 = .{ .x = .pixels(e.position.x.whole()), .depth = .pixels(e.position.depth.whole()), .height = .pixels(e.position.height.whole() + above) };
    const h = w.spawnWithin(a.tick.kinds, kind, places.from, places.to, at, .right) catch return;
    if (a.tick.actor(@This(), h)) |t| knock(t, right);
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

/// Taken up from a situation in its state: standing (solid, in front, as it is); flying, in
/// its flight's look (the traces do not tell its side, nor its meetings with the floor).
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    const n = a.numbers();
    if ((n.in_front orelse 0) != 0) a.entity.flags.in_front = true;
    switch (a.mind.state) {
        .start => {},
        .stand => {
            a.animate(.stand);
            a.entity.flags.solid = n.solid != 0;
        },
        .flying => a.animate(.fly),
    }
    const from_camera = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}
