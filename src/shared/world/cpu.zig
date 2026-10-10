//! The CPU's play (PLAN item 30): a player's pad at a display tick from what the round's world
//! shows, the same on every machine. The fight's rule is sor-remaster's runner's bot (the agent
//! host's `bot`): holding a foe, the knees; hurt, food lying goes first; else the nearest enemy or
//! boss out of hiding, which it lines up with in depth, comes to the jab's reach of from across,
//! faces, and jabs at every other tick; with none, it walks right, jabbing at a solid thing that
//! stops it.
const std = @import("std");
const input = @import("../input.zig");
const world_mod = @import("world.zig");
const entity = @import("entity.zig");
const kinds_mod = @import("kinds.zig");
const behaviours = @import("behaviours.zig");

const World = world_mod.World;
const Entity = entity.Entity;
const Kinds = kinds_mod.Kinds;

/// The rule's distances (sor-remaster's runner's): the depth within which it is level with its
/// foe, the reach it jabs from across (its jab's), the least across it keeps; the health under
/// which food comes first; how far ahead across and in depth a solid thing stops its walk.
const level = 3;
const reach = 34;
const close = 14;
const hungry = 40;
const blocked = 48;
const blocked_depth = 12;

/// Player `k`'s pad at display tick `now` by the fight's rule, while it is a fighter; null
/// otherwise.
pub fn fight(w: *const World, kinds: *const Kinds, k: u1, now: u64) ?input.Pad {
    const p = w.getConst(w.players[k].entity orelse return null) orelse return null;
    if (p.mind != .player) return null;
    const px = p.position.x.whole();
    const pd = p.position.depth.whole();
    const left = p.facing == .left;
    const jab = now % 2 == 0;
    const state = behaviours.stateName(&p.mind) orelse "";
    if (std.mem.startsWith(u8, state, "grab")) return .{ .b = jab };
    var pad: input.Pad = .{};
    if (p.health < hungry) if (nearest(w, kinds, px, pd, .food)) |e| {
        const dx = e.position.x.whole() - px;
        const dd = e.position.depth.whole() - pd;
        if (@abs(dd) > 2) {
            pad.up = dd < 0;
            pad.down = dd > 0;
        }
        if (@abs(dx) > 6) {
            pad.left = dx < 0;
            pad.right = dx > 0;
        }
        if (@as(u8, @bitCast(pad)) == 0) pad.b = jab;
        return pad;
    };
    const foe = nearest(w, kinds, px, pd, .foe) orelse {
        // No foe: right, but a solid thing ahead at its depth stops the walk, and is jabbed.
        for (&w.entities) |*e| {
            if (!e.alive() or !e.flags.solid or e.flags.hidden) continue;
            const dx = e.position.x.whole() - px;
            if (dx >= 0 and dx <= blocked and @abs(e.position.depth.whole() - pd) <= blocked_depth and !left) return .{ .b = jab };
        }
        return .{ .right = true };
    };
    const dx = foe.position.x.whole() - px;
    const dd = foe.position.depth.whole() - pd;
    if (@abs(dd) > level) {
        pad.up = dd < 0;
        pad.down = dd > 0;
    }
    if (@abs(dx) > reach) {
        pad.left = dx < 0;
        pad.right = dx > 0;
    } else if (@abs(dx) < close) {
        pad.right = dx < 0;
        pad.left = dx >= 0;
    } else if ((dx < 0) != left) {
        pad.left = dx < 0;
        pad.right = dx >= 0;
    } else if (@as(u8, @bitCast(pad)) == 0) pad.b = jab;
    return pad;
}

/// The nearest entity (across plus in depth) the rule looks for: an enemy or a boss out of
/// hiding with health left, or food lying.
fn nearest(w: *const World, kinds: *const Kinds, px: i32, pd: i32, what: enum { foe, food }) ?*const Entity {
    var best: ?*const Entity = null;
    var best_d: u32 = std.math.maxInt(u32);
    for (&w.entities) |*e| {
        if (!e.alive() or e.flags.hidden) continue;
        const k = kinds.get(e.kind.?);
        switch (what) {
            .foe => {
                const f = k.family();
                if (f != .enemy and f != .boss) continue;
                if (e.health < 0) continue;
                const now = behaviours.stateName(&e.mind) orelse "";
                if (std.mem.eql(u8, now, "appear") or std.mem.eql(u8, now, "knocked_out")) continue;
            },
            .food => if (!std.mem.eql(u8, k.name(), "apple") and !std.mem.eql(u8, k.name(), "beef")) continue,
        }
        const d = @abs(e.position.x.whole() - px) + @abs(e.position.depth.whole() - pd);
        if (d < best_d) {
            best_d = d;
            best = e;
        }
    }
    return best;
}
