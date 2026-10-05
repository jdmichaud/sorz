//! A breakable of the street (round 1's drums). It stands solid (`stand`: the fighters' walks stop
//! at its `solid` box, `Tick.keptOut`) until a player's blow lands on it while it is on the
//! screen, or a thing a player threw meets it there: then it leaves the item the round's script
//! gave it (`Tick.give`), its pieces fly off (`piece`: each falls until it is down, and goes),
//! and it blinks a while (`breaking`, then `going`) and goes. A player's blow on it opens the
//! combo's window as on an enemy; a player does not grab it. Left behind the camera, it goes, as
//! its pieces do.
//!
//! Its pieces are breakables too (the original's type $11), each set up by its entry of the
//! definition's pieces' tables. The other program's traces name its states by number
//! (`trace_states`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const world_mod = @import("../world.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { start, stand, piece, breaking, going };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .stand },
    .{ .name = "s2", .state = .piece },
    .{ .name = "s3", .state = .breaking },
    .{ .name = "s4", .state = .going },
};

pub const Mind = struct {
    state: State = .start,
    /// The ticks left of its breaking, then of its going.
    timer: u8 = 0,
    /// The kind of the item it holds.
    holds: ?entity.KindId = null,
    /// A piece: its entry of the pieces' tables, from 1 (0: the breakable itself).
    piece: u8 = 0,
    /// It was on the screen at its last tick's end: a blow lands on it.
    shown: bool = false,
    /// It broke at this tick's blows: its breaking counts from its next.
    broke: bool = false,
};

pub const Animation = enum { stand, blink, piece_1, piece_2, piece_3 };
pub const Sound = enum { shatter };

pub const Numbers = struct {
    /// Its height when it stands.
    height: i16,
    /// The ticks it blinks breaking, then going.
    breaking: u8,
    going: u8,
    /// Its pieces, and where they start from its place: across, in depth (the item's place
    /// less), each higher than the last.
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
    /// Each piece's speed across and up at first, its frame (`piece_N`), its offset across.
    piece_speed_x: [10]i32,
    piece_speed_up: [10]i32,
    piece_frame: [10]u8,
    piece_offset: [10]i8,
};

pub fn think(a: Actor) void {
    a.entity.flags.still = true;
    switch (a.mind.state) {
        .start => start(a),
        .stand => {},
        .piece => if (!fly(a)) return,
        .breaking => if (a.mind.broke) {
            a.mind.broke = false;
        } else {
            a.mind.timer -%= 1;
            if (a.mind.timer == 0) {
                a.mind.timer = a.numbers().going;
                a.mind.state = .going;
            }
        },
        .going => {
            a.mind.timer -%= 1;
            if (a.mind.timer == 0) return a.remove();
        },
    }
    const n = a.numbers();
    if (a.tick.behindCamera(a.entity.position.x, n.left_behind)) return a.remove();
    const from_camera = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}

/// It stands solid at its height; a piece takes its frame.
fn start(a: Actor) void {
    if (a.mind.piece != 0) {
        const k = a.tables().piece_frame[a.mind.piece - 1];
        a.animate(switch (k) {
            1 => .piece_1,
            2 => .piece_2,
            else => .piece_3,
        });
        a.mind.state = .piece;
        return;
    }
    a.animate(.stand);
    a.entity.flags.solid = true;
    a.entity.position.height = .parts(a.numbers().height, a.entity.position.height.frac());
    a.mind.state = .stand;
}

/// A piece flies by its speed; down at the ground, it goes; else it falls faster. False when
/// it went.
fn fly(a: Actor) bool {
    const e = a.entity;
    e.position = e.position.add(e.velocity);
    if (e.position.height.whole() >= a.tick.world.ground.whole()) {
        a.remove();
        return false;
    }
    e.velocity.height = e.velocity.height.add(a.numbers().piece_gravity);
    return true;
}

/// A blow or a thing thrown that meets it, standing on the screen, breaks it. The blow lands
/// (a player's opens its combo's window) unless a piece found no place: the original's
/// breakable then clears what its striker landed, the blows of this tick on others
/// before it too, so that a jab that broke it as it struck an enemy opens no window.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (a.mind.state != .stand or !a.mind.shown) return false;
    if (breaks(a)) return true;
    a.tick.landingCleared(blow.attacker);
    return false;
}

/// It breaks: no longer solid, it sounds, leaves its item where it stood, blinks, and its
/// pieces fly off in the items' free places. Whether every piece found one.
fn breaks(a: Actor) bool {
    const n = a.numbers();
    const t = a.tables();
    const w = a.tick.world;
    a.entity.flags.solid = false;
    a.sound(.shatter);
    const at = a.entity.position;
    if (a.mind.holds) |item| {
        a.mind.holds = null;
        leave(a.tick, item, at);
    }
    a.mind.timer = n.breaking;
    a.mind.state = .breaking;
    a.mind.broke = true;
    a.animate(.blink);
    var height = at.height.whole();
    for (0..@min(n.pieces, t.piece_speed_x.len)) |k| {
        height -= n.piece_above;
        const place: fixed.Vec3 = .{
            .x = .pixels(at.x.whole() + n.piece_x + t.piece_offset[k]),
            .depth = .pixels(at.depth.whole() + n.piece_depth),
            .height = .pixels(height),
        };
        const places = world_mod.World.item_places;
        const h = w.spawnWithin(a.tick.kinds, a.entity.kind.?, places.from, places.to, place, .right) catch return false;
        const p = w.get(h).?;
        p.velocity = .{ .x = .of(t.piece_speed_x[k]), .height = .of(t.piece_speed_up[k]) };
        p.mind.breakable.piece = @intCast(k + 1);
    }
    return true;
}

/// A thing of the street that held `item` leaves it where it stood, `at` (its whole pixels), in
/// the items' places (`World.spawnItem`; none free: it is lost), as the original's do.
pub fn leave(t: *tick.Tick, item: entity.KindId, at: fixed.Vec3) void {
    const place: fixed.Vec3 = .{ .x = .pixels(at.x.whole()), .depth = .pixels(at.depth.whole()), .height = .pixels(at.height.whole()) };
    _ = t.world.spawnItem(t.kinds, item, place) catch {};
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
/// breaking or going, blinking, its ticks gone down; a piece, in its first frame (the traces do
/// not tell which).
pub fn takeUp(a: Actor, elapsed: u32) void {
    const n = a.numbers();
    const gone: u8 = @intCast(@min(elapsed, 255));
    switch (a.mind.state) {
        .start => {},
        .stand => {
            a.animate(.stand);
            a.entity.flags.solid = true;
        },
        .piece => a.animate(.piece_1),
        .breaking => {
            a.animate(.blink);
            a.mind.timer = n.breaking -| gone;
        },
        .going => {
            a.animate(.blink);
            a.mind.timer = n.going -| gone;
        },
    }
    if (a.mind.timer == 0 and (a.mind.state == .breaking or a.mind.state == .going)) a.mind.timer = 1;
    const from_camera = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}
