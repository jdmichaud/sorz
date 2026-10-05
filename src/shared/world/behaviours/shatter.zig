//! A crate of round 6 that shatters. It stands solid (`stand`: the fighters' walks stop at its
//! `solid` box, `Tick.keptOut`) until a player's blow lands on it while it is on the screen, or a
//! thing a player threw meets it there: then it leaves the item the round's script gave it
//! (`Tick.give`), sounds, blinks a while (`breaking`) and goes; its pieces fly off (`piece`), in
//! the effects' free places (none free: the rest are not made, and the blow does not land), each
//! falling until it meets the floor under it, where it goes. A player does not grab it. Left
//! behind the camera, it goes, as its pieces do.
//!
//! Its pieces are crates too (the original's type $41, a byte marking them), each set up by its
//! entry of the definition's pieces' tables. The other program's traces name its states by
//! number (`trace_states`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const world_mod = @import("../world.zig");
const breakable = @import("breakable.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { start, stand, breaking, piece };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .stand },
    .{ .name = "s2", .state = .breaking },
    .{ .name = "s3", .state = .piece },
};

pub const Mind = struct {
    state: State = .start,
    /// The ticks left of its breaking.
    timer: u8 = 0,
    /// The kind of the item it holds.
    holds: ?entity.KindId = null,
    /// It is a piece.
    piece: bool = false,
    /// It was on the screen at its last tick's end: a blow lands on it.
    shown: bool = false,
    /// It broke at this tick's blows: its breaking counts from its next.
    broke: bool = false,
};

pub const Animation = enum { stand, breaking, piece };
pub const Sound = enum { shatter };

pub const Numbers = struct {
    /// Its height when it stands.
    height: i16,
    /// The ticks it blinks breaking, then it goes.
    breaking: u8,
    /// Its pieces, and where they start from its place: across, in depth, each higher than
    /// the last; what each tick adds to a piece's speed down.
    pieces: u8,
    piece_x: i16,
    piece_depth: i16,
    piece_above: i16,
    piece_gravity: Fixed,
    /// It goes this far behind the camera's place across.
    left_behind: i16,
    /// On the screen: its place across less the camera's from `screen_from` up to `screen_to`
    /// (excluded).
    screen_from: i16,
    screen_to: i16,
};

pub const Tables = struct {
    /// Each piece's speed across and up at first, its offset across.
    piece_speed_x: [8]i32,
    piece_speed_up: [8]i32,
    piece_offset: [8]i8,
};

pub fn think(a: Actor) void {
    a.entity.flags.still = true;
    switch (a.mind.state) {
        .start => start(a),
        .stand => {},
        .breaking => if (a.mind.broke) {
            a.mind.broke = false;
        } else {
            a.mind.timer -%= 1;
            if (a.mind.timer == 0) return a.remove();
        },
        .piece => if (!fly(a)) return,
    }
    const n = a.numbers();
    if (a.tick.behindCamera(a.entity.position.x, n.left_behind)) return a.remove();
    const from_camera = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}

/// It stands solid at its height; a piece flies in its look.
fn start(a: Actor) void {
    if (a.mind.piece) {
        a.animate(.piece);
        a.mind.state = .piece;
        return;
    }
    a.animate(.stand);
    a.entity.flags.solid = true;
    a.entity.position.height = .parts(a.numbers().height, a.entity.position.height.frac());
    a.mind.state = .stand;
}

/// A piece flies by its speed; at or below the floor under it (a wall's at once), it goes; else
/// it falls faster. False when it went.
fn fly(a: Actor) bool {
    const e = a.entity;
    e.position = e.position.add(e.velocity);
    if (a.tick.floorUnder(e.position)) |floor| if (!e.position.height.lessThan(floor)) {
        a.remove();
        return false;
    };
    e.velocity.height = e.velocity.height.add(a.numbers().piece_gravity);
    return true;
}

/// A blow or a thing thrown that meets it, standing on the screen, shatters it. The blow lands
/// unless a piece found no place: the original's crate then clears what its striker landed.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (a.mind.state != .stand or !a.mind.shown) return false;
    if (shatters(a)) return true;
    a.tick.landingCleared(blow.attacker);
    return false;
}

/// It shatters: no longer solid, it sounds, leaves its item where it stood, blinks, and its
/// pieces fly off in the effects' free places. Whether every piece found one.
fn shatters(a: Actor) bool {
    const n = a.numbers();
    const t = a.tables();
    const w = a.tick.world;
    a.entity.flags.solid = false;
    a.sound(.shatter);
    const at = a.entity.position;
    if (a.mind.holds) |item| {
        a.mind.holds = null;
        breakable.leave(a.tick, item, at);
    }
    a.mind.timer = n.breaking;
    a.mind.state = .breaking;
    a.mind.broke = true;
    a.keepAnimating(.breaking);
    var height = at.height.whole();
    for (0..@min(n.pieces, t.piece_speed_x.len)) |k| {
        height -= n.piece_above;
        const place: fixed.Vec3 = .{
            .x = .pixels(at.x.whole() + n.piece_x + t.piece_offset[k]),
            .depth = .pixels(at.depth.whole() + n.piece_depth),
            .height = .pixels(height),
        };
        const places = world_mod.World.effect_places;
        const h = w.spawnWithin(a.tick.kinds, a.entity.kind.?, places.from, places.to, place, .right) catch return false;
        const p = w.get(h).?;
        p.velocity = .{ .x = .of(t.piece_speed_x[k]), .height = .of(t.piece_speed_up[k]) };
        p.mind.shatter.piece = true;
    }
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

/// Taken up from a situation in its state, `elapsed` ticks after it entered it: standing, solid;
/// breaking, blinking, its ticks gone down; a piece, in its look.
pub fn takeUp(a: Actor, elapsed: u32) void {
    const n = a.numbers();
    switch (a.mind.state) {
        .start => {},
        .stand => {
            a.animate(.stand);
            a.entity.flags.solid = true;
        },
        .breaking => {
            a.animate(.breaking);
            a.mind.timer = n.breaking -| @as(u8, @intCast(@min(elapsed, 255)));
            if (a.mind.timer == 0) a.mind.timer = 1;
        },
        .piece => {
            a.mind.piece = true;
            a.animate(.piece);
        },
    }
    const from_camera = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}
