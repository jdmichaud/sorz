//! The pepper shaker (round 2 has one in an oil drum, round 4 one under a cone): a weapon
//! (weapon.zig's body and states) its holder throws with its plain blow. Thrown
//! (`Tick.throwWeapon`), it leaves the hand ahead of it and below, up and across the way it faces,
//! a thing thrown, and falls faster each tick (`falling`). Dropped from a hand, it falls too. A
//! hit it gave or took, or the ground under it, bursts it (`bursting`): it hides, its cloud shows a
//! while in the weapons' places (`cloud`), and its pinches of pepper come `grain_gap` ticks apart
//! at their places around it (`grain`, each a thing thrown, the shaker's last holder's), in the
//! last free place of the items' and below (none: it tries again `grain_gap` ticks later); each
//! goes at its last frame, and the shaker with its last pinch. What the shaker or a pinch meets
//! sneezes (`Reaction.sneeze`): it stops a while, unharmed. Its numbers and frames are its
//! definition's (`entities/pepper.json`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const world_mod = @import("../world.zig");
const weapon = @import("weapon.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());
const C = weapon.Of(@This());

pub const State = enum { start, lying, falling, held, blinking_out, bursting, cloud, grain };

/// The other program's traces name its states as its bottle's.
pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "breaking", .state = .bursting },
    .{ .name = "splash", .state = .cloud },
    .{ .name = "shard", .state = .grain },
};

pub const Mind = struct {
    state: State = .start,
    body: weapon.Body = .{},
    /// What it is: the shaker, or its cloud or one of its pinches of pepper.
    part: enum { shaker, cloud, grain } = .shaker,
    /// Its holder threw it: it flies from its next turn.
    thrown: bool = false,
    /// A hit it gave or took since its last turn.
    hit: bool = false,
    /// Its last holder, whose things thrown its pinches are.
    by: ?Handle = null,
    /// The ticks left of its wait (to its next pinch; of a cloud).
    timer: u8 = 0,
    /// Its next pinch.
    grain: u8 = 0,
};

pub const Animation = enum { cloud, grain };

pub const Numbers = struct {
    power: u8,
    uses: u8,
    blink: u8,
    drop: Fixed,
    left_behind: i16,
    /// Thrown: its speed across and up, how far ahead of the hand and below it it starts.
    throw_speed: Fixed,
    throw_up: Fixed,
    throw_ahead: i16,
    throw_below: i16,
    /// Falling, what each tick adds to its speed down.
    fall_gravity: Fixed,
    /// Burst: the ticks to its first pinch, then between two; its cloud's ticks; its pinches,
    /// each going at its animation's frame `grain_last_frame`.
    first_grain: u8,
    grain_gap: u8,
    cloud_ticks: u8,
    grains: u8,
    grain_last_frame: u8,
};

pub const Tables = struct {
    /// Each pinch's place from the shaker's: across, in height.
    grain_x: [8]i16,
    grain_height: [8]i16,
};

pub fn think(a: Actor) void {
    const m = a.mind;
    a.entity.flags.still = true;
    if (m.state == .start) a.entity.flags.in_front = a.tick.thingsInFront();
    if (m.state == .start and m.part != .shaker) {
        start(a);
    } else switch (m.state) {
        .held => if (m.thrown) throws(a) else held(a),
        .falling => if (!fall(a)) return,
        .bursting => if (!scatter(a)) return,
        .cloud => {
            m.timer -%= 1;
            if (m.timer == 0) return a.remove();
        },
        .grain => if (a.frame() == a.numbers().grain_last_frame) return a.remove(),
        else => if (!C.act(a)) return,
    }
    if (a.entity.alive()) _ = C.leftBehind(a);
    m.hit = false;
}

/// A cloud or a pinch starts: worn out (none takes it), in its animation; a pinch is a thing
/// thrown.
fn start(a: Actor) void {
    const m = a.mind;
    m.body.taken = a.numbers().uses;
    if (m.part == .cloud) {
        a.animate(.cloud);
        a.entity.flags.hidden = false;
        m.state = .cloud;
        return;
    }
    a.animate(.grain);
    if (m.by) |by| a.entity.missile = missile(a, by);
    m.state = .grain;
}

/// A thing thrown of the shaker's, by `by`: what it meets sneezes.
fn missile(a: Actor, by: Handle) entity.Missile {
    return .{ .by = by, .damage = a.numbers().power, .reaction = .sneeze };
}

/// Held: its holder noted; dropped, it falls (weapon.zig).
fn held(a: Actor) void {
    if (a.entity.holder) |h| a.mind.by = h;
    _ = C.act(a);
}

/// Thrown from its holder's hand: ahead of it the way it faces and below, up and across, a thing
/// thrown, falling.
fn throws(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    const m = a.mind;
    const by = e.holder orelse return;
    const way: i32 = e.facing.sign();
    m.thrown = false;
    m.by = by;
    e.holder = null;
    e.flags.hidden = false;
    e.position.x = e.position.x.add(.pixels(n.throw_ahead * way));
    e.position.height = e.position.height.add(.pixels(n.throw_below));
    e.velocity.x = .parts(@intCast(n.throw_speed.whole() * way), e.velocity.x.frac());
    e.velocity.height = .parts(@intCast(n.throw_up.whole()), e.velocity.height.frac());
    e.missile = missile(a, by);
    m.state = .falling;
}

/// Falling: a hit, or the ground under it, bursts it; else it falls faster. False when it went.
fn fall(a: Actor) bool {
    const e = a.entity;
    if (a.mind.hit) return bursts(a);
    e.velocity.height = e.velocity.height.add(a.numbers().fall_gravity);
    if (a.atGround()) return bursts(a);
    e.position = e.position.add(e.velocity);
    return true;
}

/// It bursts: hidden, no longer a thing thrown, its cloud where it is in the weapons' places
/// (none free: none), its first pinch due.
fn bursts(a: Actor) bool {
    const n = a.numbers();
    const e = a.entity;
    const m = a.mind;
    e.flags.hidden = true;
    e.missile = null;
    m.state = .bursting;
    m.timer = n.first_grain;
    const places = world_mod.World.weapon_places;
    const at: fixed.Vec3 = .{ .x = .pixels(e.position.x.whole()), .depth = .pixels(e.position.depth.whole()), .height = .pixels(e.position.height.whole()) };
    const h = a.tick.world.spawnWithin(a.tick.kinds, e.kind.?, places.from, places.to, at, .right) catch return true;
    const s = a.tick.world.get(h).?;
    s.mind.pepper.part = .cloud;
    s.mind.pepper.timer = n.cloud_ticks;
    // Unseen until its start (the original draws nothing with no animation set yet).
    s.flags.hidden = true;
    s.mind.pepper.body.taken = n.uses;
    return true;
}

/// Burst: when its wait runs out, its next pinch at its place around it, in the last free place
/// of the items' and below (none: it tries again after the next wait); with its last, it goes.
/// False when it went.
fn scatter(a: Actor) bool {
    const n = a.numbers();
    const t = a.tables();
    const e = a.entity;
    const m = a.mind;
    m.timer -%= 1;
    if (m.timer != 0) return true;
    m.timer = n.grain_gap;
    const k = @min(m.grain, t.grain_x.len - 1);
    const at: fixed.Vec3 = .{
        .x = .pixels(e.position.x.whole() + t.grain_x[k]),
        .depth = .pixels(e.position.depth.whole()),
        .height = .pixels(e.position.height.whole() + t.grain_height[k]),
    };
    const h = a.tick.world.spawnLast(a.tick.kinds, e.kind.?, at) catch return true;
    const s = a.tick.world.get(h).?;
    s.mind.pepper.part = .grain;
    s.mind.pepper.by = m.by;
    s.mind.pepper.body.taken = n.uses;
    if (m.grain + 1 >= n.grains) {
        a.remove();
        return false;
    }
    m.grain += 1;
    return true;
}

/// Its holder threw it.
pub fn hurled(a: Actor) void {
    a.mind.thrown = true;
}

/// Its blow landed: thrown, it bursts at its next turn.
pub fn blowLanded(a: Actor, target: Handle) void {
    _ = target;
    a.mind.hit = true;
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

pub fn takeable(a: Actor) bool {
    return a.mind.part == .shaker and C.takeable(a);
}

pub fn takeUp(a: Actor, elapsed: u32) void {
    C.takeUp(a, elapsed);
}

pub fn takeUpTaken(a: Actor, times: u8) void {
    a.mind.body.taken = times;
}
