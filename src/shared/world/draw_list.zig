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
//! drawn on the ground under its entity, just behind it.
//!
//! Not reproduced (decision D4, the sprite limits): the original draws at most 15 objects a
//! band, and an object past them neither shows nor advances its animation at that tick; and it
//! has 8 shadows.
const std = @import("std");
const render = @import("../render/root.zig");
const entity = @import("entity.zig");
const world_mod = @import("world.zig");
const tick_mod = @import("tick.zig");
const systems = @import("systems.zig");

const Entity = entity.Entity;
const World = world_mod.World;
const Tick = tick_mod.Tick;
const capacity = entity.capacity;

/// How far off the screen an entity goes before it leaves the world, in pixels from the
/// screen's top-left corner: left of `left` or from `right` on, above `top` or from `bottom` on.
/// An entity marked `stays` stays.
pub const far_off_screen: struct { left: i32, right: i32, top: i32, bottom: i32 } = .{
    .left = -1024,
    .right = 1152,
    .top = -112,
    .bottom = 384,
};

/// The bands of depth the order sorts in: four units of depth each.
const band_depth = 4;
const band_count = systems.ground_depths.near / band_depth + 1;

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

/// The depth the order compares, on the ground's depths.
fn depthOf(e: *const Entity) i32 {
    return std.math.clamp(e.position.depth.whole(), systems.ground_depths.far, systems.ground_depths.near);
}

pub fn build(t: *Tick) void {
    const w = t.world;
    const out = t.out;
    out.sprites.clear();

    var buf: [capacity]u8 = undefined;
    var drawn: [capacity]u8 = undefined;
    var n: usize = 0;
    for (w.updateOrder(&buf)) |i| {
        const e = &w.entities[i];
        if (e.flags.hidden or e.flags.blinked or out.shown[i] == null) continue;
        if (!e.flags.stays and farOff(screenPlace(w, e))) {
            w.remove(w.handleAt(i).?);
            out.shown[i] = null;
            continue;
        }
        drawn[n] = i;
        n += 1;
    }
    var front: [capacity]u8 = undefined;
    order(w, drawn[0..n], &front);

    // Back to front: the last of the order first; a shadow just behind its entity.
    var k = n;
    while (k > 0) {
        k -= 1;
        const i = front[k];
        const e = &w.entities[i];
        const shown = out.shown[i].?;
        const p = screenPlace(w, e);
        if (t.kinds.shadow) |shadow| if (t.kindOf(e).definition.shadow) {
            var y = (e.position.depth.whole() >> 1) + w.ground.whole();
            if (!e.flags.on_screen) y -= w.camera.y.whole();
            out.sprites.append(.{ .frame = shadow, .x = p.x, .y = y, .palette = shadow.palette, .priority = shadow.priority or e.flags.in_front });
        };
        out.sprites.append(.{
            .frame = shown.frame,
            .x = p.x,
            .y = p.y,
            .flip_x = shown.mirrored,
            .palette = shown.frame.palette +% e.palette,
            .priority = shown.frame.priority or e.flags.in_front,
        });
        e.flags.behind = false;
    }
}

/// The original's order of `places` (in the world's order) into `front`, the first in front.
pub fn order(w: *const World, places: []const u8, front: *[capacity]u8) void {
    // The bands' starts, by a count of each band's entities, then the entities in the world's
    // order within each band, the nearest band first.
    var starts: [band_count + 1]usize = @splat(0);
    for (places) |i| starts[band_count - 1 - band(&w.entities[i]) + 1] += 1;
    for (1..starts.len) |b| starts[b] += starts[b - 1];
    var next = starts;
    for (places) |i| {
        const b = band_count - 1 - band(&w.entities[i]);
        front[next[b]] = i;
        next[b] += 1;
    }
    for (0..band_count) |b| selectionSort(w, front[starts[b]..starts[b + 1]]);
}

fn band(e: *const Entity) usize {
    return @intCast(@divTrunc(depthOf(e), band_depth));
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
