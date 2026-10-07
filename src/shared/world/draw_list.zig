//! The draw list (DESIGN.md W5, the last system of a logic tick): the entities' frames as the
//! renderer's sprites (render.Sprite: a frame by reference to the content, its origin on the
//! screen, mirrored or not, its palette and priority), back to front, which `Screen.sprites`
//! takes as it is. As in the original, ordering the drawing is part of the logic: an entity far
//! off the screen leaves the world here.
//!
//! The order, the original's rule (`order`): nearer entities (a greater depth) in front. The
//! entities are taken in the world's order (the players' first, then the others in their places'
//! order) into bands of four units of depth; each band, the nearest first, is sorted as the
//! original sorts it: a selection sort that brings the nearest of the rest to each position in
//! turn, swapping it there, with an entity marked `behind` giving way to one not marked at an
//! equal depth; the first of the list is in front. The sort is not stable: of two entities at one
//! depth, which is in front depends on the others of their band, and that is the original's
//! picture. The `behind` mark lasts one drawing.
//!
//! A shadow (an entity whose definition has one, when the content has the shadow's frame) is
//! drawn on the ground under its entity, just behind it, while the entity is in the air: the
//! original's shadow goes as its entity stands on the floor (on round 1's floor; the floor's
//! cells, PLAN item 13, will say where it stays). The original's shadow is an object of its own
//! (type $4A, in the eight places the weapons share: their places are kept as the original's,
//! shadows.zig), sorted as any object at its owner's depth, which can draw it over another sprite
//! there (a slammed enemy's hand and feet under a vaulting player), and reorder the entities at
//! nearly one depth; drawn just behind its owner here, and the order by depth alone, a known
//! difference the user accepted as more correct (a candidate for PLAN item 23 only). Each
//! sprite's place, rank and depth go with the draw list (`Output.sprite_info`), for the checks
//! to draw it again in the original's order.
//!
//! Not reproduced (decision D4, the sprite limits): the original draws at most 15 objects a
//! band, and an object past them neither shows nor advances its animation at that tick.
const std = @import("std");
const render = @import("../render/root.zig");
const entity = @import("entity.zig");
const world_mod = @import("world.zig");
const tick_mod = @import("tick.zig");
const systems = @import("systems.zig");
const shadows = @import("shadows.zig");
const output = @import("output.zig");

const Entity = entity.Entity;
const World = world_mod.World;
const Tick = tick_mod.Tick;
const capacity = entity.capacity;

/// How far off the screen an entity goes before it leaves the world, in pixels from the
/// screen's top-left corner: left of `left` or from `right` on, above `top` or from `bottom` on.
/// An entity marked `stays` stays, and while the special attack is under way none goes (its
/// camera runs back and ahead past the round's things; the police car sees to its own going).
pub const far_off_screen: struct { left: i32, right: i32, top: i32, bottom: i32 } = .{
    .left = -1024,
    .right = 1152,
    .top = -112,
    .bottom = 384,
};

/// The bands of depth the order sorts in: four units of depth each.
const band_depth = 4;
const band_count: usize = systems.ground_depths.near / band_depth + 1;

pub const Place = struct { x: i32, y: i32 };

/// Where the entity's origin is on the screen: its place across less the camera's, and half its
/// depth plus its height less the camera's line (no camera for an entity fixed on the screen).
pub fn screenPlace(w: *const World, e: *const Entity) Place {
    var p: Place = .{ .x = e.position.x.whole(), .y = e.position.screenY() };
    if (!e.flags.on_screen) {
        p.x -= w.camera.x.whole();
        p.y -= w.camera.y.whole();
    }
    return p;
}

fn farOff(p: Place) bool {
    const f = far_off_screen;
    return p.x < f.left or p.x >= f.right or p.y < f.top or p.y >= f.bottom;
}

fn farOffAt(x: i32, y: i32) bool {
    return farOff(.{ .x = x, .y = y });
}

/// The depth the order compares, on the ground's depths.
fn depthOf(e: *const Entity) i32 {
    return std.math.clamp(e.position.depth.whole(), systems.ground_depths.far, systems.ground_depths.near);
}

pub fn build(t: *Tick) void {
    listOf(t, true);
}

/// The draw list of the frames the entities show (`Output.shown`); an entity far off the screen
/// goes from the world when `remove_far_off` (the tick's), else it is only not drawn (the draw
/// list made again from a world loaded as it was, which must not change it).
pub fn listOf(t: *Tick, remove_far_off: bool) void {
    const w = t.world;
    const out = t.out;
    out.sprites.clear();
    out.sprite_info.clear();

    var buf: [capacity]u8 = undefined;
    var drawn: [capacity]u8 = undefined;
    var gone: [capacity]u8 = undefined;
    var n: usize = 0;
    var n_gone: usize = 0;
    for (w.updateOrder(&buf)) |i| {
        const e = &w.entities[i];
        if (e.flags.hidden or e.flags.blinked or out.shown[i] == null) continue;
        // One held follows its holder (a weapon in a hand): it does not go of itself, nor with
        // its holder going at this tick (it follows its holder's emptied place from the next).
        if (!e.flags.stays and e.holder == null and !w.special and farOff(screenPlace(w, e))) {
            gone[n_gone] = i;
            n_gone += 1;
            out.shown[i] = null;
            continue;
        }
        drawn[n] = i;
        n += 1;
    }
    if (remove_far_off) for (gone[0..n_gone]) |i| w.remove(w.handleAt(i).?);
    // The shadows' places far off the screen go too (shadows.zig).
    if (remove_far_off and !w.special) shadows.goFarOff(w, farOffAt);
    // A hidden entity's shadow, held in its place, shows where that place lies (the original's
    // shadow is an object of its own: a player out of lives as it starts to wait).
    var shadow_only: [capacity]bool = @splat(false);
    for (w.updateOrder(&buf)) |i| {
        const e = &w.entities[i];
        if (!e.flags.hidden or e.flags.blinked or !t.kindOf(e).definition.shadow) continue;
        if (heldShadow(w, i) == null) continue;
        shadow_only[i] = true;
        drawn[n] = i;
        n += 1;
    }
    var front: [capacity]u8 = undefined;
    order(w, drawn[0..n], &front);
    var rank: [capacity]u8 = @splat(0);
    for (w.updateOrder(&buf), 0..) |i, r| rank[i] = @intCast(r);

    // Back to front: the last of the order first; a shadow just behind its entity.
    var k = n;
    while (k > 0) {
        k -= 1;
        const i = front[k];
        const e = &w.entities[i];
        if (shadow_only[i]) {
            const s = heldShadow(w, i).?;
            const shadow = t.kinds.shadow orelse continue;
            const x = s.position.x.whole() - w.camera.x.whole();
            const y = s.position.screenY() - w.camera.y.whole();
            out.sprites.append(.{ .frame = shadow, .x = x, .y = y, .palette = shadow.palette, .priority = shadow.priority or e.flags.in_front });
            out.sprite_info.append(.{ .place = shadowPlace(w, i), .rank = rank[i], .depth = @intCast(depthOf(e)), .band_depth = @intCast(depthOf(e)), .shadow = true });
            continue;
        }
        const shown = out.shown[i].?;
        const p = screenPlace(w, e);
        // Over a hole of a floor by cells (round 4's) the shadow lies at the hole's floor, far
        // below the screen: none. An entity that found no shadow's place has none (shadows.zig).
        const floor = t.floorUnder(e.position);
        if (t.kinds.shadow) |shadow| if (floor) |f| if (t.kindOf(e).definition.shadow and !e.flags.shadowless and e.flags.has_shadow and e.position.height.lessThan(f)) {
            var y = (e.position.depth.whole() >> 1) + f.whole();
            if (!e.flags.on_screen) y -= w.camera.y.whole();
            out.sprites.append(.{ .frame = shadow, .x = p.x, .y = y, .palette = shadow.palette, .priority = shadow.priority or e.flags.in_front });
            out.sprite_info.append(.{ .place = shadowPlace(w, i), .rank = rank[i], .depth = @intCast(depthOf(e)), .band_depth = @intCast(depthOf(e)), .shadow = true });
        };
        out.sprites.append(.{
            .frame = shown.frame,
            .x = p.x,
            .y = p.y,
            .flip_x = shown.mirrored,
            .palette = shown.frame.palette +% e.palette,
            .priority = shown.frame.priority or e.flags.in_front,
            .colours = coloursOf(t, i, e),
        });
        out.sprite_info.append(.{ .place = i, .rank = rank[i], .depth = @intCast(depthOf(e)), .band_depth = @intCast(bandDepth(w, i)), .behind = e.flags.behind });
        e.flags.behind = false;
    }
}

/// The shadow the entity in place `i` holds, when it has had its turn (shadows.zig).
fn heldShadow(w: *const World, i: usize) ?shadows.Shadow {
    for (w.shadows) |s| if (s) |x| if (x.owner == i and x.turned) return x;
    return null;
}

/// The place of the shadow of the entity in place `i` (shadows.zig), or `no_place` when none holds
/// one (the original's eight were taken).
fn shadowPlace(w: *const World, i: usize) u8 {
    for (w.shadows, 0..) |s, k| if (s) |x| if (x.owner == i) return @intCast(shadows.first + k);
    return output.no_place;
}

/// The colour map a player's fighter (at place `i`) is drawn with (`Player.colours`), when its
/// character's definition has it.
fn coloursOf(t: *const Tick, i: usize, e: *const Entity) ?*const render.screen.ColourMap {
    for (&t.world.players) |*p| {
        const m = p.colours orelse continue;
        const h = p.entity orelse continue;
        if (h.index != i or e.kind != p.character) continue;
        const maps = t.kindOf(e).definition.colour_maps;
        return if (m < maps.len) &maps[m].map else null;
    }
    return null;
}

/// The original's order of `places` (in the world's order) into `front`, the first in front.
pub fn order(w: *const World, places: []const u8, front: *[capacity]u8) void {
    // The bands' starts, by a count of each band's entities, then the entities in the world's
    // order within each band, the nearest band first.
    var starts: [band_count + 1]usize = @splat(0);
    for (places) |i| starts[band_count - 1 - band(w, i) + 1] += 1;
    for (1..starts.len) |b| starts[b] += starts[b - 1];
    var next = starts;
    for (places) |i| {
        const b = band_count - 1 - band(w, i);
        front[next[b]] = i;
        next[b] += 1;
    }
    for (0..band_count) |b| selectionSort(w, front[starts[b]..starts[b + 1]]);
}

/// The band of the entity in place `i`: by its depth; a player's, by its depth as the others'
/// turns began (`Player.band_depth`: the original takes the players' bands before the other
/// objects' handlers), though its depth now sorts it within that band.
fn band(w: *const World, i: usize) usize {
    return @intCast(@divTrunc(bandDepth(w, i), band_depth));
}

fn bandDepth(w: *const World, i: usize) i32 {
    for (w.players) |p| if (p.entity) |h| if (h.index == i) if (p.band_depth) |d| return d;
    return depthOf(&w.entities[i]);
}

/// The original's sort of a band: each position in turn takes the nearest of the rest, swapped
/// with each nearer one found; at an equal depth an entity marked `behind` gives way.
fn selectionSort(w: *const World, list: []u8) void {
    if (list.len < 2) return;
    for (0..list.len - 1) |i| {
        var best = &w.entities[list[i]];
        for (i + 1..list.len) |j| {
            const cand = &w.entities[list[j]];
            const cd = depthOf(cand);
            const bd = depthOf(best);
            if (cd > bd or (cd == bd and best.flags.behind and !cand.flags.behind)) {
                const tmp = list[i];
                list[i] = list[j];
                list[j] = tmp;
                best = cand;
            }
        }
    }
}
