//! The police car of the special attack and its parts (special_knockdown.zig brings the car when
//! the camera has run back far enough):
//! - the car (`arriving`): unseen, it queues its art (the round's `special` stream, by its
//!   caller) once the round's art is loaded, and waits while it loads; then the siren, and it
//!   drives in from the screen's left, slowing (`driving`), brakes past the screen's left part
//!   (`braking`) and stays (`parked`); its officer rides with it (`riding`), still once it
//!   brakes;
//! - a moment after it brakes, player 1's bazooka (player 2's gun) rises out of it (`rising`),
//!   aims a moment (`aiming`) and fires (`firing`): player 1's flash then smoke (`puffing`,
//!   `fading`), whose end sends the camera running ahead; player 2's gunfire a while (`fading`),
//!   the same;
//! - the car, its officer and the bazooka go when the camera's run ahead leaves them behind.
//! Its numbers, animations and sounds are its definition's (`entities/police_car.json`); its
//! colours lie over the enemies' from its siren (the special attack gives theirs back).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const Part = enum(u3) { car, officer, bazooka, flash, smoke, gun, gunfire };

pub const State = enum { arriving, driving, braking, parked, riding, rising, aiming, firing, puffing, fading };

pub const Mind = struct {
    state: State = .arriving,
    part: Part = .car,
    /// The second player's special attack.
    second: bool = false,
    /// A count of ticks; the bazooka's top (its height, rising, at most).
    timer: u16 = 0,
    top: i16 = 0,
    /// The car's officer and the car of a part (their places in the world).
    other: ?u8 = null,
    /// Made at this tick: its first tick only sets it up.
    fresh: bool = true,
    /// The car's art was queued.
    queued: bool = false,
};

pub const Animation = enum { car, officer, bazooka, gun, flash, smoke, gunfire };
pub const Sound = enum { siren, brakes, bazooka, gun };

pub const Numbers = struct {
    /// The car's depth and height as it comes.
    depth: i16,
    height: i16,
    /// Its speed in, slowing each tick; past the camera's place and `brakes_ahead` it brakes,
    /// and stays `parked` ticks before the bazooka rises; its officer rides `officer_depth` in
    /// front.
    drive: Fixed,
    slowing: Fixed,
    brakes_ahead: i16,
    parked: u16,
    officer_depth: i16,
    /// The bazooka (the gun): from the car's height `bazooka_up`, behind it `bazooka_depth`, it
    /// rises at `rise` to `bazooka_top` above the car's feet, aims `aim` ticks and stops at frame
    /// `aim_ends` of its firing; player 1's smoke comes `smoke_after` ticks after the flash, each
    /// gone from frame `puff_ends`; player 2's gunfire lasts `gunfire` ticks.
    bazooka_up: i16,
    bazooka_top: i16,
    bazooka_depth: i16,
    rise: Fixed,
    aim: u16,
    aim_ends: u8,
    smoke_after: u16,
    puff_ends: u8,
    gunfire: u16,
    /// Drawn this far behind the camera's place across, a part goes.
    gone_behind: i16,
};

/// The places of the special attack's things: the world's last eighteen of the original's.
pub const places: struct { from: usize, to: usize } = .{ .from = 50, .to = 68 };

pub fn think(a: Actor) void {
    const m = a.mind;
    a.entity.flags.still = true;
    if (m.fresh) {
        m.fresh = false;
        return;
    }
    switch (m.state) {
        .arriving => arriving(a),
        .driving => driving(a),
        .braking => braking(a),
        .parked => {},
        .riding => riding(a),
        .rising => rising(a),
        .aiming => aiming(a),
        .firing => if (a.frame() >= a.numbers().aim_ends) a.pause(true),
        .puffing => puffing(a),
        .fading => fading(a),
    }
    if (!a.entity.alive() or a.entity.flags.hidden) return;
    // Drawn far behind the camera, the car, its officer and the bazooka go.
    switch (m.part) {
        .car, .officer, .bazooka, .gun => {
            const behind = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
            if (behind < a.numbers().gone_behind) a.remove();
        },
        else => {},
    }
}

/// The car is made unseen, its art to load: queued at once when the round's art is loaded.
pub fn arrive(a: Actor, second: bool) void {
    const m = a.mind;
    m.* = .{ .state = .arriving, .part = .car, .second = second };
    a.entity.flags.hidden = true;
    a.animate(.car);
    queueArt(a);
}

/// Whether the round's art still loads as the car looks (the logic tick's second half).
fn artLoading(a: Actor) bool {
    const plan = a.tick.plan orelse return false;
    return plan.art_loading[1];
}

/// Its art queued, when the round's is loaded: the stream of its caller's.
fn queueArt(a: Actor) void {
    if (artLoading(a)) return;
    a.mind.queued = true;
    a.tick.out.streamed = .{ .special = @intFromBool(a.mind.second) };
}

/// Its art queued, then loaded: the siren, it shows and drives in, its officer with it.
fn arriving(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    e.flags.hidden = true;
    if (!m.queued) return queueArt(a);
    if (artLoading(a)) return;
    a.sound(.siren);
    a.tick.out.colour_loads.append(.police);
    m.state = .driving;
    e.flags.hidden = false;
    e.velocity.x = .parts(@intCast(n.drive.whole()), e.velocity.x.frac());
    // The officer: the highest place free.
    var i: usize = places.to;
    while (i > places.from) {
        i -= 1;
        if (a.tick.world.entities[i].alive()) continue;
        const h = a.tick.world.spawnIn(a.tick.kinds, e.kind.?, i, .{ .x = e.position.x, .depth = e.position.depth.add(.pixels(n.officer_depth)), .height = e.position.height }, .right) catch return;
        const o = a.tick.actor(@This(), h) orelse return;
        o.mind.* = .{ .state = .riding, .part = .officer, .second = m.second, .other = @intCast(a.handle.index) };
        o.animate(.officer);
        m.other = @intCast(i);
        return;
    }
}

/// Slowing as it drives; past the screen's left part it brakes, its officer still.
fn driving(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    e.velocity.x = e.velocity.x.add(n.slowing);
    e.position = e.position.add(e.velocity);
    if (a.tick.world.camera.x.whole() + n.brakes_ahead >= e.position.x.whole()) return;
    a.sound(.brakes);
    m.state = .braking;
    m.timer = n.parked;
    if (m.other) |at| if (a.tick.world.handleAt(at)) |h| if (a.tick.actor(@This(), h)) |o| o.pause(true);
}

/// Parked a moment, then the bazooka (the gun) rises out of it.
fn braking(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    m.timer -= 1;
    if (m.timer != 0) return;
    m.state = .parked;
    const at = e.position;
    const h = spawnPart(a, .{ .x = at.x, .depth = at.depth.sub(.pixels(n.bazooka_depth)), .height = at.height.sub(.pixels(n.bazooka_up)) }) orelse return;
    const b = a.tick.actor(@This(), h) orelse return;
    b.mind.* = .{ .state = .rising, .part = if (m.second) .gun else .bazooka, .second = m.second, .top = @intCast(at.height.whole() - n.bazooka_top) };
    b.animate(if (m.second) .gun else .bazooka);
    b.pause(true);
    b.entity.velocity.height = .parts(@intCast(n.rise.whole()), b.entity.velocity.height.frac());
}

/// A part in the first free of the special attack's places, from the lowest.
fn spawnPart(a: Actor, at: fixed.Vec3) ?Handle {
    return a.tick.world.spawnWithin(a.tick.kinds, a.entity.kind.?, places.from, places.to, at, .right) catch null;
}

/// The officer rides along: the car's place across.
fn riding(a: Actor) void {
    const at = a.mind.other orelse return;
    const h = a.tick.world.handleAt(at) orelse return;
    const car = a.other(h) orelse return;
    a.entity.position.x = .parts(@intCast(car.position.x.whole()), a.entity.position.x.frac());
}

/// The bazooka rises to its top; then it aims.
fn rising(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    e.position = e.position.add(e.velocity);
    if (@as(u16, @bitCast(@as(i16, @intCast(e.position.height.whole())))) > @as(u16, @bitCast(m.top))) return;
    m.state = .aiming;
    m.timer = n.aim;
}

/// Aimed, it fires: player 1's flash, player 2's gunfire, and its sound.
fn aiming(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.timer -= 1;
    if (m.timer != 0) return;
    m.state = .firing;
    a.pause(false);
    const h = spawnPart(a, a.entity.position) orelse return;
    const f = a.tick.actor(@This(), h) orelse return;
    if (m.second) {
        f.mind.* = .{ .state = .fading, .part = .gunfire, .second = true, .timer = n.gunfire };
        f.animate(.gunfire);
        a.sound(.gun);
    } else {
        f.mind.* = .{ .state = .puffing, .part = .flash, .timer = n.smoke_after };
        f.animate(.flash);
        a.sound(.bazooka);
    }
}

/// Player 1's flash: its smoke comes a moment in; it goes at its frame `puff_ends`.
fn puffing(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (m.timer != 0) {
        m.timer -= 1;
        if (m.timer == 0) if (spawnPart(a, a.entity.position)) |h| if (a.tick.actor(@This(), h)) |s| {
            s.mind.* = .{ .state = .fading, .part = .smoke };
            s.animate(.smoke);
        };
    }
    if (a.frame() >= n.puff_ends) a.remove();
}

/// Player 1's smoke at its frame `puff_ends`, player 2's gunfire out of time: it goes, and the
/// camera runs ahead from the next tick.
fn fading(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (m.part == .gunfire) {
        m.timer -= 1;
        if (m.timer != 0) return;
        a.entity.flags.hidden = true;
    } else if (a.frame() < n.puff_ends) return;
    if (a.tick.world.camera.run) |*r| r.state = .ahead;
    a.remove();
}
