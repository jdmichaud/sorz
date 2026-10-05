//! The helper of a two-player round 3 (boss_r3.zig): hidden, made by the boss whose entry has a
//! bar of its own, it watches him and the other boss: both beaten, the section's enemies are
//! knocked down; each done with his knockout goes, with his part; both gone, the round is won.
const std = @import("std");
const tick = @import("../tick.zig");
const entity = @import("../entity.zig");
const boss = @import("boss_r3.zig");

const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { start, watch };

pub const Mind = struct {
    state: State = .start,
    /// The boss who made it, and the other.
    owner: ?Handle = null,
    other: ?Handle = null,
    /// The bosses beaten (the other's first, the owner's second: their knockouts tell it), and
    /// those gone (1 the owner, 2 the other).
    beaten: struct { first: bool = false, second: bool = false } = .{},
    gone: u2 = 0,
    told: bool = false,
};

pub fn think(a: Actor) void {
    const m = a.mind;
    a.entity.flags.still = true;
    a.entity.flags.hidden = true;
    a.entity.flags.stays = true;
    if (m.state == .start) {
        m.other = otherBoss(a);
        m.state = .watch;
    }
    if (m.beaten.first and m.beaten.second and !m.told) {
        m.told = true;
        a.tick.bossBeaten();
    }
    for ([_]struct { h: ?Handle, bit: u2 }{ .{ .h = m.owner, .bit = 1 }, .{ .h = m.other, .bit = 2 } }) |b| {
        const h = b.h orelse continue;
        const ba = a.tick.actor(boss, h) orelse continue;
        if (!ba.mind.done) continue;
        m.gone |= b.bit;
        if (ba.mind.part) |p| a.tick.world.remove(p);
        a.tick.world.remove(h);
    }
    if (m.gone != 3) return;
    a.tick.roundWon();
    a.remove();
}

/// The first boss of the round's kind among the enemies that is not its owner.
fn otherBoss(a: Actor) ?Handle {
    const w = a.tick.world;
    const k = a.tick.kinds.find("boss_r3") orelse return null;
    const places = @import("../world.zig").World.enemy_places;
    for (places.from..places.to) |i| {
        const o = &w.entities[i];
        if (!o.alive() or o.kind == null or o.kind.? != k) continue;
        const h = w.handleAt(i).?;
        if (a.mind.owner) |own| if (own.eql(h)) continue;
        return h;
    }
    return null;
}
