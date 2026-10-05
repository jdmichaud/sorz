//! Round 6's press: a weight on a rod, hanging at its height (`watch`) until a player comes near
//! below it across (from `near_behind` behind its place, excluded, to `near_span` on from there,
//! included; player 1 looked at first). It shakes a while (`shake`), its cells of the round's
//! plane with it; then it drops (`drop`), faster each tick. At its own turn it strikes with its
//! two boxes (the front's first, then the back's) the first player each meets: a blow of its
//! power that knocks down; at their turns the enemies meet its look's box as they meet a thing
//! thrown. Each height of its table it passes leaves a link of its rod behind (`press_link`, in
//! the last free place). At the floor it shakes the screen and bounces (`bounce`) its times, the
//! first with its sound; it rests, rises back to its height (`rise`), rests again, and watches
//! (`again`). It stands still while the special attack runs. Drawn far enough left of the
//! screen, it goes.
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const kinds_mod = @import("../kinds.zig");
const press_link = @import("press_link.zig");

const Fixed = fixed.Fixed;
const Actor = tick.Actor(@This());

pub const State = enum { start, watch, shake, drop, bounce, rest, rise, risen, again };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .watch },
    .{ .name = "s2", .state = .shake },
    .{ .name = "s3", .state = .drop },
    .{ .name = "s4", .state = .bounce },
    .{ .name = "s5", .state = .rest },
    .{ .name = "s6", .state = .rise },
    .{ .name = "s7", .state = .risen },
    .{ .name = "s8", .state = .again },
};

pub const Mind = struct {
    state: State = .start,
    /// The ticks left of its shake or of its rest.
    ticks: u8 = 0,
    /// Its bounces on the floor.
    bounces: u8 = 0,
    /// The next height of its table that leaves a link.
    link: u8 = 0,
    /// Its lamp is lit (its cells of the plane in their first look), as it shakes.
    shaken: bool = false,
};

pub const Animation = enum { hang };
pub const Box = enum { drop_front, drop_back };
pub const Sound = enum { bounce, thud };

pub const Numbers = struct {
    /// The height it hangs at; its blow's damage, on a player; on an enemy (the original's press
    /// takes an enemy's place, whose things hit for less).
    height: i16,
    power: u8,
    enemy_damage: u8,
    /// A player is near from `near_behind` behind its place across (excluded) to `near_span` on
    /// from there (included).
    near_behind: i16,
    near_span: i16,
    /// The ticks it shakes.
    shake: u8,
    /// Its speed down as it drops (its whole pixels only), what each tick adds to it.
    drop_speed: Fixed,
    drop_gravity: Fixed,
    /// The floor's height it bounces at; its speed off it, what each tick adds to it, its
    /// bounces.
    floor: i16,
    bounce_speed: Fixed,
    bounce_gravity: Fixed,
    bounces: u8,
    /// The ticks it rests on the floor and risen; its speed rising.
    rest: u8,
    rise_speed: Fixed,
    /// It goes when its place across less the camera's plus `drawn_offset` is below
    /// `drawn_left`.
    drawn_left: i16,
    drawn_offset: i16,
    /// Its lamp's cells' row of the round's plane.
    lamp_y: u8,
};

pub const Tables = struct {
    /// The heights it passes as it drops, each leaving a link (the last past the floor).
    link_heights: [5]i16,
    /// Its lamp's two cells of the round's plane, by its place: their column of the plane's
    /// cells as the original's video memory holds them (the nearest to it of those across the
    /// round), and their row (`Numbers.lamp_y`).
    lamp_x: [6]u8,
};

/// A press's lamp: its cells' column (of the plane's cells as the original's video memory holds
/// them) and row, and whether it is lit.
pub const Lamp = struct { x: u8, y: u8, lit: bool };

/// The lamp of entity `e`, a press of kind `k`, by its place (none: no lamp; not a press).
pub fn lampOf(k: *const kinds_mod.Kind, e: *const entity.Entity) ?Lamp {
    const m = switch (e.mind) {
        .press => |m| m,
        else => return null,
    };
    const p = e.spawn.place orelse return null;
    const t: *const Tables = @ptrCast(@alignCast(k.tables orelse return null));
    if (p >= t.lamp_x.len) return null;
    return .{ .x = t.lamp_x[p], .y = kinds_mod.numbersOf(@This(), k).lamp_y, .lit = m.shaken };
}

pub fn think(a: Actor) void {
    const e = a.entity;
    e.flags.still = true;
    if (a.tick.world.special) return;
    const n = a.numbers();
    const m = a.mind;
    switch (m.state) {
        .start => {
            e.position.height = .parts(n.height, e.position.height.frac());
            a.animate(.hang);
            m.state = .watch;
        },
        .watch => if (near(a)) {
            m.state = .shake;
            m.ticks = n.shake;
        },
        .shake => {
            m.ticks -%= 1;
            if (m.ticks == 0) {
                m.state = .drop;
                e.velocity.height = .parts(@intCast(n.drop_speed.whole()), e.velocity.height.frac());
                m.link = 0;
                e.missile = .{ .by = a.handle, .damage = n.enemy_damage, .on_enemies = true };
            } else m.shaken = !m.shaken;
        },
        .drop => drop(a),
        .bounce => {
            e.velocity.height = e.velocity.height.add(n.bounce_gravity);
            e.position = e.position.add(e.velocity);
            if (e.position.height.whole() >= n.floor) {
                if (m.bounces == 0) a.sound(.bounce);
                e.velocity.height = e.velocity.height.neg();
                m.bounces +%= 1;
                if (m.bounces >= n.bounces) {
                    m.ticks = n.rest;
                    m.state = .rest;
                }
            }
        },
        .rest, .risen => {
            m.ticks -%= 1;
            if (m.ticks == 0) {
                e.velocity.height = n.rise_speed;
                m.state = if (m.state == .rest) .rise else .again;
            }
        },
        .rise => {
            e.position = e.position.add(e.velocity);
            if (e.position.height.whole() < n.height) {
                m.state = .risen;
                m.ticks = n.rest;
                e.position.height = .parts(n.height, e.position.height.frac());
            }
        },
        .again => m.state = .watch,
    }
    if (e.position.x.whole() - a.tick.world.camera.x.whole() + n.drawn_offset < n.drawn_left) a.remove();
}

/// Whether a player is near below it: player 1 looked at first.
fn near(a: Actor) bool {
    const n = a.numbers();
    const from = a.entity.position.x.whole() - n.near_behind;
    for (a.tick.world.players) |p| {
        const h = p.entity orelse continue;
        const pe = a.tick.world.getConst(h) orelse continue;
        const x = pe.position.x.whole();
        if (x > from and x <= from + n.near_span) return true;
    }
    return false;
}

/// It strikes with its two boxes, moves down faster, leaves a link past each height of its
/// table, and at the floor bounces up, shaking the screen, a thing thrown no more.
fn drop(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const blow: tick.Blow = .{ .attacker = a.handle, .damage = n.power, .reaction = .knock_down, .push = .zero };
    a.strikePlayers(.drop_front, blow);
    a.strikePlayers(.drop_back, blow);
    e.velocity.height = e.velocity.height.add(n.drop_gravity);
    e.position = e.position.add(e.velocity);
    const heights = &a.tables().link_heights;
    if (m.link < heights.len and heights[m.link] < e.position.height.whole()) {
        m.link += 1;
        leaveLink(a);
    }
    if (e.position.height.whole() < n.floor) return;
    e.velocity.height = n.bounce_speed;
    m.bounces = 0;
    m.state = .bounce;
    if (!a.tick.world.special and a.tick.world.camera.shake == 0) {
        a.tick.shake();
        a.sound(.thud);
    }
    e.missile = null;
}

/// A link of its rod at its whole pixels, in the last free place (none: none).
fn leaveLink(a: Actor) void {
    const kind = a.tick.kinds.find(press_link.kind_name) orelse return;
    const p = a.entity.position;
    const at: fixed.Vec3 = .pixels(p.x.whole(), p.depth.whole(), p.height.whole());
    const h = a.tick.world.spawnLast(a.tick.kinds, kind, at) catch return;
    if (a.tick.actor(press_link, h)) |l| l.mind.press = a.handle;
}

/// Whether it has risen back (resting there, or about to watch again).
pub fn risen(a: Actor) bool {
    return a.mind.state == .risen or a.mind.state == .again;
}

/// Whether it rises.
pub fn rising(a: Actor) bool {
    return a.mind.state == .rise;
}

/// Taken up from a situation in its state: its look; dropping, a thing thrown.
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    if (a.mind.state == .start) return;
    a.animate(.hang);
    if (a.mind.state == .drop) a.entity.missile = .{ .by = a.handle, .damage = a.numbers().enemy_damage, .on_enemies = true };
}
