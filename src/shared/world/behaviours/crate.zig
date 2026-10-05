//! A crate (round 3's stack of tyres on the beach). It stands solid at its height (`stand`)
//! until a player's blow lands on it while it is on the screen, or a thing a player threw meets
//! it there: then it is no longer solid, sounds, leaves the item the round's script gave it
//! (`Tick.give`), and breaks into `pieces` pieces, crates of their own in the items' places while
//! one is free, the first `above` over its height and each next `step` lower, at their speeds up
//! and across (to the side the one that struck it faces); then it goes. A piece shows its frame
//! still (`piece`); from its next tick it falls, faster each tick, and at the ground bounces up at
//! half its speed, sounding, blinking from then on; at its `bounces`th landing it goes. A blow on
//! the crate lands; a player does not grab it. Left behind the camera, a crate or a piece goes.
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const world_mod = @import("../world.zig");
const breakable = @import("breakable.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { start, stand, piece };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .stand },
    .{ .name = "s2", .state = .piece },
};

pub const Mind = struct {
    state: State = .start,
    /// A piece: its place among the pieces, from 1 (0: the crate itself).
    piece: u8 = 0,
    /// A piece's landings so far.
    landings: u8 = 0,
    /// The kind of the item it holds.
    holds: ?entity.KindId = null,
    /// It was on the screen at its last tick's end: a blow lands on it.
    shown: bool = false,
    /// It broke at this tick's blows: it goes at its turn.
    broke: bool = false,
};

/// Its stack; a piece's frame, then none (a piece blinks once it bounced).
pub const Animation = enum { stand, piece };
pub const Sound = enum { broken };

pub const Numbers = struct {
    /// Its height when it stands.
    height: i16,
    /// Its pieces, where the first starts above its height and how much lower each next.
    pieces: u8,
    above: i16,
    step: i16,
    /// Added to a piece's speed down each tick.
    gravity: Fixed,
    /// A piece goes at this landing.
    bounces: u8,
    /// It goes this far behind the camera's place across.
    left_behind: i16,
    /// On the screen: its place across less the camera's from `screen_from` up to `screen_to`
    /// (excluded).
    screen_from: i16,
    screen_to: i16,
};

pub const Tables = struct {
    /// Each piece's speed up (whole pixels; up is negative), and across to the left and to the
    /// right.
    piece_up: [4]i32,
    piece_left: [4]i32,
    piece_right: [4]i32,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    e.flags.still = true;
    if (a.mind.broke) return a.remove();
    switch (a.mind.state) {
        .start => if (a.mind.piece != 0) {
            a.animate(.piece);
            a.pause(true);
            a.mind.state = .piece;
        } else {
            a.animate(.stand);
            e.flags.solid = true;
            e.position.height = .parts(a.numbers().height, e.position.height.frac());
            a.mind.state = .stand;
        },
        .stand => {},
        .piece => if (!fall(a)) return,
    }
    const n = a.numbers();
    const from_camera = e.position.x.whole() - a.tick.world.camera.x.whole();
    if (from_camera <= -n.left_behind) return a.remove();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}

/// A piece falls by its speed, faster each tick; at the ground it lands: it bounces up at half
/// its speed, sounding and blinking, or goes at its last landing. False when it went.
fn fall(a: Actor) bool {
    const e = a.entity;
    const n = a.numbers();
    e.velocity.height = e.velocity.height.add(n.gravity);
    e.position = e.position.add(e.velocity);
    if (!a.atGround()) return true;
    e.position.height = .parts(@intCast(a.tick.world.ground.whole()), e.position.height.frac());
    a.pause(false);
    a.mind.landings += 1;
    if (a.mind.landings >= n.bounces) {
        a.remove();
        return false;
    }
    e.velocity.height = .{ .raw = (-e.velocity.height.raw) >> 1 };
    a.sound(.broken);
    return true;
}

/// A blow or a thing thrown that meets it, standing on the screen, breaks it, its pieces flying
/// to the side the one that struck it faces: the blow lands.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (a.mind.state != .stand or !a.mind.shown) return false;
    const by = a.other(blow.attacker) orelse return false;
    breaks(a, by.facing);
    return true;
}

/// It breaks: no longer solid, it sounds, leaves its item where it stood, and its pieces fly
/// off to `side` from the items' free places; it goes at its turn.
fn breaks(a: Actor, side: entity.Facing) void {
    const n = a.numbers();
    const t = a.tables();
    const w = a.tick.world;
    const e = a.entity;
    e.flags.solid = false;
    a.sound(.broken);
    const at = e.position;
    if (a.mind.holds) |item| {
        a.mind.holds = null;
        breakable.leave(a.tick, item, at);
    }
    var height = at.height.whole() - n.above;
    for (0..@min(n.pieces, t.piece_up.len)) |k| {
        const place: fixed.Vec3 = .{ .x = .pixels(at.x.whole()), .depth = .pixels(at.depth.whole()), .height = .pixels(height) };
        const places = world_mod.World.item_places;
        const h = w.spawnWithin(a.tick.kinds, e.kind.?, places.from, places.to, place, .right) catch break;
        const p = w.get(h).?;
        const across = if (side == .left) t.piece_left[k] else t.piece_right[k];
        p.velocity = .{ .x = .pixels(@intCast(across)), .height = .pixels(@intCast(t.piece_up[k])) };
        p.mind.crate.piece = @intCast(k + 1);
        height += n.step;
    }
    a.mind.broke = true;
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

/// Taken up from a situation in its state: standing, solid; a piece, still in its first frame
/// (the traces do not tell its landings).
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    const n = a.numbers();
    switch (a.mind.state) {
        .start => {},
        .stand => {
            a.animate(.stand);
            a.entity.flags.solid = true;
        },
        .piece => {
            a.animate(.piece);
            a.pause(true);
            a.mind.piece = 1;
        },
    }
    const from_camera = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}
