//! A rolling shutter an enemy lies in wait behind (round 1's Galsias and brawlers placed so): the
//! enemy puts it up where it stands (`Tick.putUpShutter`). Unseen itself, it stacks its slats
//! upward (`stack`: each a shutter too, `slat` then `roll`), and waits (`wait`) for the player it
//! watches to come near: then its enemy shows, and the slats roll up with the shutter's sound,
//! the lowest farthest, each one above a little less; the top one stays (`rolled`), and once it
//! is done the enemy is let out (`letOut`) and the shutter goes. Its numbers, its slat's look and
//! its sound are its definition's (`entities/shutter.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const behaviours = @import("../behaviours.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const world_mod = @import("../world.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { stack, slat, roll, wait, rolled };

/// Its states as another program's traces name them (by number: they have no names there).
pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .stack },
    .{ .name = "s1", .state = .slat },
    .{ .name = "s2", .state = .roll },
    .{ .name = "s3", .state = .wait },
    .{ .name = "s4", .state = .rolled },
};

pub const Mind = struct {
    state: State = .stack,
    /// The shutter's enemy (on the shutter), or the shutter (on a slat).
    owner: ?Handle = null,
    /// The shutter: the player it watches; it opened; its top slat is done.
    target: ?Handle = null,
    open: bool = false,
    done: bool = false,
    /// A slat: its place from the top (0, the top one, stays), its ticks to roll, rolling.
    place: u8 = 0,
    count: u8 = 0,
    rolling: bool = false,
};

pub const Animation = enum { slat };
pub const Sound = enum { roll };

pub const Numbers = struct {
    /// Its slats, from `above` over its place, `spacing` apart.
    slats: u8,
    above: i16,
    spacing: i16,
    /// The lowest slat rolls this many ticks, each above `less` fewer; the top one waits `top`.
    roll: u8,
    less: u8,
    top: u8,
    /// Its slats' speed up as they roll.
    roll_speed: Fixed,
    /// The player it watches comes this near across before its place: it opens.
    near: i16,
    /// Its enemy waits this far across from it (the enemies' `shutter_beside`).
    beside: i16,
};

pub fn think(a: Actor) void {
    a.entity.flags.still = true;
    switch (a.mind.state) {
        .stack => stack(a),
        .slat => {
            a.animate(.slat);
            a.mind.state = .roll;
        },
        .roll => roll(a),
        .wait => wait(a),
        .rolled => {},
    }
}

/// The shutter: the player it watches; unseen; its slats, in the enemies' free places, the
/// lowest first.
fn stack(a: Actor) void {
    const n = a.numbers();
    const w = a.tick.world;
    a.mind.target = nearest(a);
    a.entity.flags.hidden = true;
    const p = a.entity.position;
    var height = p.height.whole() - n.above;
    var ticks = n.roll;
    var last: ?Handle = null;
    var k = n.slats;
    while (k > 0) {
        k -= 1;
        height -= n.spacing;
        const at: fixed.Vec3 = .{ .x = .pixels(p.x.whole()), .depth = .pixels(p.depth.whole()), .height = .pixels(height) };
        const s = w.spawnWithin(a.tick.kinds, a.entity.kind.?, world_mod.World.enemy_places.from, world_mod.World.enemy_places.to, at, .right) catch break;
        const m = &w.get(s).?.mind.shutter;
        m.* = .{ .state = .slat, .owner = a.handle, .place = k, .count = ticks };
        ticks -%= n.less;
        last = s;
    }
    if (last) |s| w.get(s).?.mind.shutter.count = n.top;
    a.mind.state = .wait;
}

/// The player in play nearest across (the original's enemies' choice).
fn nearest(a: Actor) ?Handle {
    const w = a.tick.world;
    var best: ?Handle = null;
    var best_d: i32 = 0;
    for (w.players) |pl| {
        const h = pl.entity orelse continue;
        const e = w.getConst(h) orelse continue;
        if (e.flags.hidden) continue;
        const d: i32 = @intCast(@abs(e.position.x.whole() - a.entity.position.x.whole()));
        if (best == null or d <= best_d) {
            best = h;
            best_d = d;
        }
    }
    return best;
}

/// The shutter waits for its player to come near: its enemy shows; once its top slat is done,
/// the enemy is let out and the shutter goes.
fn wait(a: Actor) void {
    const n = a.numbers();
    const owner = a.mind.owner orelse return a.remove();
    if (!a.mind.open) {
        const t = a.other(a.mind.target orelse return) orelse return;
        if (a.entity.position.x.whole() - n.near > t.position.x.whole()) return;
        a.mind.open = true;
        if (a.other(owner)) |e| e.flags.hidden = false;
    }
    if (!a.mind.done) return;
    a.tick.letOut(owner);
    a.remove();
}

/// Taken up from a situation another program recorded, which says only the state and where it
/// was put up (the traces follow no move of scenery): a shutter waiting finds its enemy (the one
/// coming in through it, beside it) and its player; a slat finds its shutter, and its place by
/// its height over the shutter's. Whether the shutter has opened, and when, the situation tells
/// apart (`takeUpOpened`).
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    const n = a.numbers();
    const w = a.tick.world;
    const x = a.entity.position.x.whole();
    switch (a.mind.state) {
        .wait => {
            a.entity.flags.hidden = true;
            a.mind.target = nearest(a);
            for (&w.entities, 0..) |*e, i| {
                if (!e.alive() or e.position.x.whole() != x + n.beside) continue;
                const name = behaviours.stateName(&e.mind) orelse continue;
                if (!std.mem.eql(u8, name, "shutter_entry")) continue;
                a.mind.owner = w.handleAt(i);
                e.flags.hidden = true;
            }
        },
        .slat, .roll, .rolled => {
            a.animate(.slat);
            if (a.mind.state == .rolled) return;
            a.mind.state = .roll;
            const sh = shutterOver(a) orelse return a.remove();
            a.mind.owner = sh;
            const first = w.get(sh).?.position.height.whole() - n.above;
            const k = @as(i32, n.slats) - @divTrunc(first - a.entity.position.height.whole(), n.spacing);
            a.mind.place = @intCast(std.math.clamp(k, 0, @as(i32, n.slats) - 1));
            const count: i32 = if (a.mind.place == 0) n.top else @as(i32, n.roll) - @as(i32, n.less) * (@as(i32, n.slats) - 1 - a.mind.place);
            a.mind.count = @intCast(count);
        },
        else => {},
    }
}

/// Taken up from a situation in which the shutter opened `ago` ticks before: its enemy shows,
/// and its slats have rolled since.
pub fn takeUpOpened(a: Actor, ago: u32) void {
    const n = a.numbers();
    const w = a.tick.world;
    if (a.mind.state != .wait) return;
    a.mind.open = true;
    if (a.mind.owner) |o| if (a.other(o)) |e| {
        e.flags.hidden = false;
    };
    const rolled: i32 = @intCast(@min(ago + 1, 255));
    for (&w.entities, 0..) |*e, i| {
        if (!e.alive() or e.kind != a.entity.kind) continue;
        const m = &e.mind.shutter;
        if (m.state != .roll) continue;
        const o = m.owner orelse continue;
        if (!o.eql(a.handle)) continue;
        m.rolling = true;
        const left = @as(i32, m.count) - rolled;
        if (left <= 0) {
            if (m.place == 0) {
                m.state = .rolled;
                a.mind.done = true;
            } else w.remove(w.handleAt(i).?);
            continue;
        }
        m.count = @intCast(left);
        if (m.place != 0) {
            e.flags.behind = true;
            e.position.height = e.position.height.add(n.roll_speed.times(rolled));
        }
    }
}

/// The shutter waiting over the slat's place.
fn shutterOver(a: Actor) ?Handle {
    const w = a.tick.world;
    for (&w.entities, 0..) |*e, i| {
        if (!e.alive() or e.kind != a.entity.kind or e.position.x.whole() != a.entity.position.x.whole()) continue;
        if (e.mind.shutter.state == .wait) return w.handleAt(i);
    }
    return null;
}

/// A slat waits for its shutter to open, then rolls up a while and goes; the top one only
/// counts, then marks the shutter done and stays.
fn roll(a: Actor) void {
    const n = a.numbers();
    const sh = a.other(a.mind.owner orelse return a.remove()) orelse return a.remove();
    if (!a.mind.rolling) {
        if (!sh.mind.shutter.open) return;
        a.mind.rolling = true;
        a.sound(.roll);
    }
    a.mind.count -%= 1;
    if (a.mind.count != 0) {
        if (a.mind.place == 0) return;
        a.entity.flags.behind = true;
        a.entity.position.height = a.entity.position.height.add(n.roll_speed);
        return;
    }
    if (a.mind.place != 0) return a.remove();
    sh.mind.shutter.done = true;
    a.mind.state = .rolled;
}
