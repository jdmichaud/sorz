//! The bottle (round 2 has one in an oil drum): a weapon (weapon.zig's body and states) its holder
//! throws with its plain blow. Thrown (`Tick.throwWeapon`), it leaves the hand ahead of it and
//! below, up and across the way it faces, a thing thrown, and falls faster each tick (`falling`).
//! Dropped from a hand, it falls too. A hit it gave or took, or the ground under it, breaks it
//! (`breaking`): it hides, its splash shows a while in the weapons' places (`splash`), and its
//! shards come `shard_gap` ticks apart at their places around it (`shard`, each a thing thrown
//! with the bottle's power, the bottle's last holder's), in the last free place of the items' and
//! below (none: it tries again `shard_gap` ticks later); each goes at its last frame, and the
//! bottle with its last shard. Its numbers and frames are its definition's
//! (`entities/bottle.json`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const world_mod = @import("../world.zig");
const weapon = @import("weapon.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());
const C = weapon.Of(@This());

pub const State = enum { start, lying, falling, held, blinking_out, breaking, splash, shard };

pub const Mind = struct {
    state: State = .start,
    body: weapon.Body = .{},
    /// What it is: the bottle, or its splash or one of its shards.
    part: enum { bottle, splash, shard } = .bottle,
    /// Its holder threw it: it flies from its next turn.
    thrown: bool = false,
    /// A hit it gave or took since its last turn.
    hit: bool = false,
    /// Its last holder, whose things thrown its shards are.
    by: ?Handle = null,
    /// The ticks left of its wait (to its next shard; of a splash).
    timer: u8 = 0,
    /// Its next shard.
    shard: u8 = 0,
};

pub const Animation = enum { splash, shard };

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
    /// Broken: the ticks to its first shard, then between two; its splash's ticks; its shards,
    /// each going at its animation's frame `shard_last_frame`.
    first_shard: u8,
    shard_gap: u8,
    splash_ticks: u8,
    shards: u8,
    shard_last_frame: u8,
};

pub const Tables = struct {
    /// Each shard's place from the bottle's: across, in height.
    shard_x: [8]i16,
    shard_height: [8]i16,
};

pub fn think(a: Actor) void {
    const m = a.mind;
    a.entity.flags.still = true;
    if (m.state == .start and m.part != .bottle) {
        start(a);
    } else switch (m.state) {
        .held => if (m.thrown) throws(a) else held(a),
        .falling => if (!fall(a)) return,
        .breaking => if (!shatter(a)) return,
        .splash => {
            m.timer -%= 1;
            if (m.timer == 0) return a.remove();
        },
        .shard => if (a.frame() == a.numbers().shard_last_frame) return a.remove(),
        else => if (!C.act(a)) return,
    }
    if (a.entity.alive()) _ = C.leftBehind(a);
    m.hit = false;
}

/// A splash or a shard starts: worn out (none takes it), in its animation; a shard is a thing
/// thrown.
fn start(a: Actor) void {
    const m = a.mind;
    m.body.taken = a.numbers().uses;
    if (m.part == .splash) {
        a.animate(.splash);
        m.state = .splash;
        return;
    }
    a.animate(.shard);
    if (m.by) |by| a.entity.missile = .{ .by = by, .damage = a.numbers().power };
    m.state = .shard;
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
    e.missile = .{ .by = by, .damage = n.power };
    m.state = .falling;
}

/// Falling: a hit, or the ground under it, breaks it; else it falls faster. False when it went.
fn fall(a: Actor) bool {
    const e = a.entity;
    if (a.mind.hit) return breaks(a);
    e.velocity.height = e.velocity.height.add(a.numbers().fall_gravity);
    if (a.atGround()) return breaks(a);
    e.position = e.position.add(e.velocity);
    return true;
}

/// It breaks: hidden, no longer a thing thrown, its splash where it is in the weapons' places
/// (none free: none), its first shard due.
fn breaks(a: Actor) bool {
    const n = a.numbers();
    const e = a.entity;
    const m = a.mind;
    e.flags.hidden = true;
    e.missile = null;
    m.state = .breaking;
    m.timer = n.first_shard;
    const places = world_mod.World.weapon_places;
    const at: fixed.Vec3 = .{ .x = .pixels(e.position.x.whole()), .depth = .pixels(e.position.depth.whole()), .height = .pixels(e.position.height.whole()) };
    const h = a.tick.world.spawnWithin(a.tick.kinds, e.kind.?, places.from, places.to, at, .right) catch return true;
    const s = a.tick.world.get(h).?;
    s.mind.bottle.part = .splash;
    s.mind.bottle.timer = n.splash_ticks;
    s.mind.bottle.body.taken = n.uses;
    return true;
}

/// Broken: when its wait runs out, its next shard at its place around it, in the last free place
/// of the items' and below (none: it tries again after the next wait); with its last, it goes.
/// False when it went.
fn shatter(a: Actor) bool {
    const n = a.numbers();
    const t = a.tables();
    const e = a.entity;
    const m = a.mind;
    m.timer -%= 1;
    if (m.timer != 0) return true;
    m.timer = n.shard_gap;
    const k = @min(m.shard, t.shard_x.len - 1);
    const at: fixed.Vec3 = .{
        .x = .pixels(e.position.x.whole() + t.shard_x[k]),
        .depth = .pixels(e.position.depth.whole()),
        .height = .pixels(e.position.height.whole() + t.shard_height[k]),
    };
    const h = a.tick.world.spawnLast(a.tick.kinds, e.kind.?, at) catch return true;
    const s = a.tick.world.get(h).?;
    s.mind.bottle.part = .shard;
    s.mind.bottle.by = m.by;
    s.mind.bottle.body.taken = n.uses;
    if (m.shard + 1 >= n.shards) {
        a.remove();
        return false;
    }
    m.shard += 1;
    return true;
}

/// Its holder threw it.
pub fn hurled(a: Actor) void {
    a.mind.thrown = true;
}

/// Its blow landed: thrown, it breaks at its next turn.
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
    return a.mind.part == .bottle and C.takeable(a);
}

pub fn takeUp(a: Actor, elapsed: u32) void {
    C.takeUp(a, elapsed);
}

pub fn takeUpTaken(a: Actor, times: u8) void {
    a.mind.body.taken = times;
}
