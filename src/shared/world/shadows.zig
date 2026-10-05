//! The shadows' places: the original's shadow is an object of its own, in one of eight places it
//! shares with the weapons (the weapons' places, World.weapon_places), and it takes that place
//! whether it is seen or not. sorz draws its shadows its own way (just behind their entities,
//! draw_list.zig: the user's choice); the places are kept here as the original takes and frees
//! them, because they decide where the things made in those places go, and whether one finds a
//! place at all (a knife Galsia that finds none for its knife fights without it).
//!
//! - After its turn, an entity of the first 50 places that takes a shadow (its kind's `shadow` or
//!   `shadow_place`, not `shadowless`) and holds none takes the first free place of the eight
//!   (no entity there, no shadow): the players after their move, the others after their turn
//!   (the enemies'), or their move (from the weapons' places on: the world's order of the
//!   original's handlers, each with its move).
//! - At its own place's turn (the movement's, in the world's order) a shadow follows its entity:
//!   it stays while its entity is above the floor under it (in the air, or over a hole), and
//!   then takes a shadow's place itself, as any object of the first 50 (a shadow's shadow, which
//!   goes at its first turn: it lies on the floor); else it goes, and its entity may take another.
//!   An entity that went leaves its shadow following its empty place (the original reads the
//!   place's cleared record: in the air at 0), until a new entity there is down.
const std = @import("std");
const fixed = @import("fixed.zig");
const entity = @import("entity.zig");
const world_mod = @import("world.zig");
const tick_mod = @import("tick.zig");

const Fixed = fixed.Fixed;
const Vec3 = fixed.Vec3;
const Tick = tick_mod.Tick;
const World = world_mod.World;

/// The places a shadow takes: the weapons' (World.weapon_places).
pub const first = 34;
pub const count = 8;

/// The places whose entities take shadows (the original's first 50 objects: World.item_places'
/// end).
const owners_below = 50;

/// A shadow in its place: the place of its entity (an entity's, or another shadow's), whether it
/// holds a shadow of its own, where it lies (its entity's place across and in depth, on the
/// floor), and whether it has had its first turn.
pub const Shadow = struct {
    owner: u8,
    has_shadow: bool = false,
    position: Vec3 = .zero,
};

/// The shadow in place `i`, if one holds it.
pub fn at(w: *World, i: usize) ?*Shadow {
    if (i < first or i >= first + count) return null;
    return if (w.shadows[i - first]) |*s| s else null;
}

/// After the turn of the one in place `i` (an entity, or a shadow that stayed): it takes a
/// shadow's place when it should.
pub fn afterTurn(t: *Tick, i: usize) void {
    const w = t.world;
    if (i >= owners_below or !t.play_mode) return;
    if (at(w, i)) |s| {
        if (s.has_shadow) return;
        if (take(w, i)) s.has_shadow = true;
        return;
    }
    const e = &w.entities[i];
    if (!e.alive() or e.flags.has_shadow or !takes(t, e)) return;
    if (take(w, i)) e.flags.has_shadow = true;
}

/// Whether the entity takes a shadow (no mark against one).
fn takes(t: *const Tick, e: *const entity.Entity) bool {
    if (e.flags.shadowless) return false;
    const d = t.kindOf(e).definition;
    return d.shadow or d.shadow_place;
}

/// The first free place of the shadows' for the one in place `owner`.
fn take(w: *World, owner: usize) bool {
    for (0..count) |k| {
        if (w.shadows[k] != null or w.entities[first + k].alive()) continue;
        w.shadows[k] = .{ .owner = @intCast(owner) };
        return true;
    }
    return false;
}

/// The turn of the shadow in place `i`: it follows its entity, or goes.
pub fn turn(t: *Tick, i: usize) void {
    const w = t.world;
    const s = at(w, i) orelse return;
    const o = s.owner;
    // Its entity: a shadow, an entity, or an empty place.
    var place: Vec3 = .zero;
    if (at(w, o)) |other| {
        place = other.position;
    } else {
        const e = &w.entities[o];
        if (e.alive()) {
            if (!takes(t, e)) return free(w, i);
            place = e.position;
        }
    }
    const floor = floorAt(t, place) orelse {
        // Over a hole: it stays, at the hole's floor.
        s.position = place;
        return;
    };
    // The original's look at the cell under it: above its floor, nothing there.
    const z = @max(place.height.whole(), 0);
    if (z >= floor) return free(w, i);
    s.position = .{ .x = place.x, .depth = place.depth, .height = .pixels(floor) };
}

/// The shadow in place `i` goes: its entity holds none any more.
fn free(w: *World, i: usize) void {
    const s = at(w, i).?;
    const o = s.owner;
    if (at(w, o)) |other| {
        other.has_shadow = false;
    } else w.entities[o].flags.has_shadow = false;
    w.shadows[i - first] = null;
}

/// The floor's height under `p` (the round's floor by cells, else its ground); null over a hole.
fn floorAt(t: *const Tick, p: Vec3) ?i32 {
    var q = p;
    if (q.x.raw < 0) q.x = .zero;
    if (q.depth.raw < 0) q.depth = .zero;
    const f = t.floorUnder(q) orelse return null;
    return f.whole();
}

test "the shadows' places are the weapons'" {
    try std.testing.expectEqual(World.weapon_places.from, first);
    try std.testing.expectEqual(World.weapon_places.to, first + count);
    try std.testing.expectEqual(World.item_places.to, owners_below);
}
