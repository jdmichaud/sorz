//! The systems of a logic tick (DESIGN.md W4), in their order, which is part of the game's
//! definition: exact may need a step moved, and then it is moved here. Each is a function over
//! the tick (tick.zig): the world, its kinds, the random generator, the pads and the output.
//!
//! The entities are updated in the world's order (`World.updateOrder`): the players' first, then
//! the others in their places' order, as the original runs its players before its other objects.
const std = @import("std");
const input = @import("../input.zig");
const content_entity = @import("../content/entity.zig");
const fixed = @import("fixed.zig");
const random = @import("random.zig");
const entity = @import("entity.zig");
const world_mod = @import("world.zig");
const kinds_mod = @import("kinds.zig");
const output = @import("output.zig");
const tick_mod = @import("tick.zig");
const draw_list = @import("draw_list.zig");

const Fixed = fixed.Fixed;
const Entity = entity.Entity;
const Handle = entity.Handle;
const World = world_mod.World;
const Kinds = kinds_mod.Kinds;
const Output = output.Output;
const Tick = tick_mod.Tick;
const Input = tick_mod.Input;
const capacity = entity.capacity;

pub const System = struct {
    name: []const u8,
    run: *const fn (*Tick) void,
};

/// The logic tick, in order.
pub const pipeline = [_]System{
    .{ .name = "commands", .run = commands },
    .{ .name = "control", .run = control },
    .{ .name = "ai", .run = ai },
    .{ .name = "movement", .run = movement },
    .{ .name = "hits", .run = hits },
    .{ .name = "grabs", .run = grabs },
    .{ .name = "pickups", .run = pickups },
    .{ .name = "script", .run = script },
    .{ .name = "camera", .run = camera },
    .{ .name = "animation", .run = animation },
    .{ .name = "sounds", .run = sounds },
    .{ .name = "draw_list", .run = draw_list.build },
};

/// One logic tick of `world`, with the pads `in`; its output in `out`.
pub fn run(world: *World, kinds: *const Kinds, rng: *random.Random, in: Input, out: *Output) void {
    out.begin();
    var t: Tick = .{ .world = world, .kinds = kinds, .random = rng, .out = out, .input = in };
    inline for (pipeline) |s| s.run(&t);
    world.tick +%= 1;
}

// 1. Input to commands ------------------------------------------------------------------------

/// The players' commands, from the pads read at the logic tick's two display ticks, as the
/// original's players read theirs: the directions as the last read has them; the buttons (A, B,
/// C, start) as either read has them, so that a press is not lost between two logic ticks. A
/// button is newly pressed at a read when the read before it did not have it.
fn commands(t: *Tick) void {
    for (&t.world.players, 0..) |*p, k| {
        const first = bits(padOf(t.input.pads[0], k));
        const last = bits(padOf(t.input.pads[1], k));
        const first_new = first & ~bits(p.last);
        const last_new = last & ~first;
        p.command = .{
            .held = @bitCast((last & directions) | ((first | last) & buttons)),
            .pressed = @bitCast((last_new & directions) | ((first_new | last_new) & buttons)),
        };
        p.last = @bitCast(last);
    }
}

const directions: u8 = bits(.{ .up = true, .down = true, .left = true, .right = true });
const buttons: u8 = ~directions;

fn bits(pad: input.Pad) u8 {
    return @bitCast(pad);
}

fn padOf(pads: input.Pads, player: usize) input.Pad {
    return if (player == 0) pads.pad1 else pads.pad2;
}

// 2. Player control ---------------------------------------------------------------------------

fn control(t: *Tick) void {
    for (t.world.players) |p| {
        const h = p.entity orelse continue;
        t.control(h, p.command);
    }
}

// 3. AI ---------------------------------------------------------------------------------------

fn ai(t: *Tick) void {
    var buf: [capacity]u8 = undefined;
    for (t.world.updateOrder(&buf)) |i| {
        const h = t.world.handleAt(i) orelse continue;
        if (t.world.playerOf(h) != null) continue;
        t.think(h);
    }
}

// 4. Movement and gravity ---------------------------------------------------------------------

/// The depths of the ground, in whole pixels: an entity drawn is kept on them (the original
/// keeps them where it orders its drawing).
pub const ground_depths: struct { near: i32, far: i32 } = .{ .far = 0, .near = 240 };

/// Each entity moves by its speed, except one held, which its holder places. In the air, it
/// lands when it has come down to the ground; otherwise its gravity adds to its speed in height.
/// A drawn entity's depth is kept on the ground's depths, its fraction kept.
fn movement(t: *Tick) void {
    var buf: [capacity]u8 = undefined;
    for (t.world.updateOrder(&buf)) |i| {
        const h = t.world.handleAt(i) orelse continue;
        const e = t.world.get(h).?;
        e.flags.landed = false;
        if (e.holder != null) continue;
        e.position = e.position.add(e.velocity);
        if (e.flags.airborne) {
            if (!e.position.height.lessThan(t.world.ground) and e.velocity.height.raw >= 0) {
                e.position.height = t.world.ground;
                e.velocity.height = .zero;
                e.flags.airborne = false;
                e.flags.landed = true;
                t.landed(h);
            } else {
                e.velocity.height = e.velocity.height.add(.of(t.kindOf(e).definition.gravity));
            }
        }
        if (t.world.get(h)) |still| if (!still.flags.hidden) keepOnGround(still);
    }
}

fn keepOnGround(e: *Entity) void {
    const d = e.position.depth.whole();
    const kept = std.math.clamp(d, ground_depths.far, ground_depths.near);
    if (kept != d) e.position.depth = .parts(@intCast(kept), e.position.depth.frac());
}

// 5. Hits -------------------------------------------------------------------------------------

/// Whether a blow of `attacker`'s team lands on `target`'s team: the players' blows land on the
/// enemies, on the neutral entities (the breakables) and on the other player (the original's
/// two players strike each other); the enemies' on the players.
pub fn blowsLand(attacker: entity.Team, target: entity.Team) bool {
    return switch (attacker) {
        .player => true,
        .enemy => target == .player,
        .neutral => false,
    };
}

/// Each entity whose move is under way and whose frame has an attack box strikes each entity
/// whose body box it meets, of a team its blows land on: the struck entity's behaviour takes
/// the blow or not (`struck`); a blow taken costs the move's damage and asks for its hit sound.
fn hits(t: *Tick) void {
    var buf: [capacity]u8 = undefined;
    const order = t.world.updateOrder(&buf);
    for (order) |ai_| {
        const ah = t.world.handleAt(ai_) orelse continue;
        for (order) |ti| {
            if (ti == ai_) continue;
            const a = t.world.get(ah) orelse break;
            const attack = a.boxes.attack orelse break;
            const move_index = a.move orelse break;
            const th = t.world.handleAt(ti) orelse continue;
            const target = t.world.get(th).?;
            const body = target.boxes.body orelse continue;
            if (!blowsLand(a.team, target.team)) continue;
            const ak = t.kindOf(a);
            if (!meet(a, &ak.definition.boxes[attack], target, &t.kindOf(target).definition.boxes[body])) continue;
            const m = ak.definition.moves[move_index];
            const away: i32 = switch (target.position.x.order(a.position.x)) {
                .lt => -1,
                .gt => 1,
                .eq => a.facing.sign(),
            };
            const blow: tick_mod.Blow = .{
                .attacker = ah,
                .damage = std.math.cast(i16, m.damage) orelse std.math.maxInt(i16),
                .reaction = m.reaction,
                .push = .{ .x = Fixed.of(m.push_x).times(away), .height = .of(m.push_height) },
            };
            if (!t.struck(th, blow)) continue;
            const struck = t.world.get(th) orelse continue;
            struck.health -|= blow.damage;
            struck.struck_by = ah;
            t.out.hits.append(.{ .attacker = ah, .target = th, .damage = blow.damage });
            if (m.hit_sound) |s| t.sound(s, ah);
        }
    }
}

/// Whether box `ab` of `a` meets box `bb` of `b`: on each axis, their spans from the entities'
/// places (whole pixels) overlap or touch.
pub fn meet(a: *const Entity, ab: *const content_entity.Box, b: *const Entity, bb: *const content_entity.Box) bool {
    return spansMeet(a.position.x.whole(), ab.across(a.boxes.mirrored), b.position.x.whole(), bb.across(b.boxes.mirrored)) and
        spansMeet(a.position.depth.whole(), ab.depth, b.position.depth.whole(), bb.depth) and
        spansMeet(a.position.height.whole(), ab.height, b.position.height.whole(), bb.height);
}

fn spansMeet(pa: i32, sa: content_entity.Span, pb: i32, sb: content_entity.Span) bool {
    return pa + sa.from <= pb + sb.to and pb + sb.from <= pa + sa.to;
}

// 6. Grabs ------------------------------------------------------------------------------------

/// An entity whose behaviour asks to grab, holding nothing and held by nothing, holds the first
/// entity (in the world's order) whose body its body meets, of a team its blows land on, free
/// too, and whose behaviour lets it (`grabbable`). The holder's behaviour places the one it
/// holds; a grab ends when either goes (`World.remove`) or a behaviour lets go.
/// TODO(PLAN item 11): the reach of a grab, its depth and its facing, from Axel's measurements.
fn grabs(t: *Tick) void {
    var buf: [capacity]u8 = undefined;
    const order = t.world.updateOrder(&buf);
    for (order) |i| {
        const h = t.world.handleAt(i) orelse continue;
        const e = t.world.get(h).?;
        if (!e.flags.wants_grab) continue;
        e.flags.wants_grab = false;
        if (e.holding != null or e.holder != null) continue;
        const body = e.boxes.body orelse continue;
        for (order) |j| {
            if (j == i) continue;
            const oh = t.world.handleAt(j) orelse continue;
            const o = t.world.get(oh).?;
            if (o.holder != null or o.holding != null or !blowsLand(e.team, o.team)) continue;
            const ob = o.boxes.body orelse continue;
            if (!meet(e, &t.kindOf(e).definition.boxes[body], o, &t.kindOf(o).definition.boxes[ob])) continue;
            if (!t.grabbable(oh, h)) continue;
            e.holding = oh;
            o.holder = h;
            t.grabbed(h, oh);
            break;
        }
    }
}

// 7. Pick-ups ---------------------------------------------------------------------------------

/// An entity whose behaviour asks to pick up takes the first weapon or item (in the world's
/// order) that nothing holds and whose body its body meets: the pick-up is noted, the picker's
/// behaviour told (`picks`), and the item goes unless its behaviour keeps it (`pickedUp`).
fn pickups(t: *Tick) void {
    var buf: [capacity]u8 = undefined;
    const order = t.world.updateOrder(&buf);
    for (order) |i| {
        const h = t.world.handleAt(i) orelse continue;
        const e = t.world.get(h).?;
        if (!e.flags.wants_pickup) continue;
        e.flags.wants_pickup = false;
        const body = e.boxes.body orelse continue;
        for (order) |j| {
            if (j == i) continue;
            const oh = t.world.handleAt(j) orelse continue;
            const o = t.world.get(oh).?;
            const family = t.kindOf(o).family();
            if (family != .item and family != .weapon) continue;
            if (o.holder != null) continue;
            const ob = o.boxes.body orelse continue;
            if (!meet(e, &t.kindOf(e).definition.boxes[body], o, &t.kindOf(o).definition.boxes[ob])) continue;
            t.out.pickups.append(.{ .item = oh, .kind = o.kind.?, .by = h });
            t.pickedUp(oh, h);
            break;
        }
    }
}

// 8. The round's script -----------------------------------------------------------------------

/// The round's script (DESIGN.md W6): its waves, its events, the camera's walls. A round's
/// content and its set pieces come with PLAN item 13; until then a world has no script.
fn script(t: *Tick) void {
    _ = t;
}

// 9. The camera -------------------------------------------------------------------------------

/// The camera stays within its limits. TODO(PLAN item 13): it follows the players across and
/// stops at the script's walls, as the original's does.
fn camera(t: *Tick) void {
    const c = &t.world.camera;
    c.x = c.x.clamp(c.x_min, c.x_max);
    c.y = c.y.clamp(c.y_min, c.y_max);
}

// 10. Animation -------------------------------------------------------------------------------

/// Each entity shows the frame it is on at this tick (noted in the output, which the draw list
/// draws), and that frame's boxes are those in use from now on; then the frame's ticks count
/// down, and when they run out the next frame comes for the next tick: after the last, the first
/// again (a looping animation) or the last stays, and the animation is done. So a frame shows
/// for its ticks from the tick its animation starts, and the logic of a tick sees the frame that
/// tick shows, as in the original, where the frame advances after it is drawn.
fn animation(t: *Tick) void {
    for (&t.world.entities, 0..) |*e, i| {
        if (!e.alive()) continue;
        const index = e.animation.index orelse continue;
        const k = t.kindOf(e);
        const an = k.definition.animations[index];
        const step = an.frames[e.animation.frame];
        const mirrored = e.facingLeft() != step.flip;
        t.out.shown[i] = .{ .frame = k.frames[index][e.animation.frame], .mirrored = mirrored };
        e.boxes = .{ .body = step.body, .attack = step.attack, .mirrored = mirrored };
        if (e.animation.done and !an.loop) continue;
        e.animation.left -|= 1;
        if (e.animation.left != 0) continue;
        if (e.animation.frame + 1 < an.frames.len) {
            e.animation.frame += 1;
        } else if (an.loop) {
            e.animation.frame = 0;
            e.animation.done = true;
        } else {
            e.animation.done = true;
            continue;
        }
        e.animation.left = an.frames[e.animation.frame].ticks;
    }
}

// 11. Sound events ----------------------------------------------------------------------------

/// The tick's sounds go out in the order they were asked for; a sound asked for twice in a tick
/// is asked for once, as the original's sound requests are.
fn sounds(t: *Tick) void {
    const list = &t.out.sounds;
    var n: usize = 0;
    for (list.items[0..list.len]) |s| {
        for (list.items[0..n]) |kept| {
            if (std.mem.eql(u8, kept.name, s.name)) break;
        } else {
            list.items[n] = s;
            n += 1;
        }
    }
    list.len = n;
}
