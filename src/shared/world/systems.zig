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
const behaviours = @import("behaviours.zig");
const script = @import("script.zig");

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

/// The logic tick, in order. As in the original, the round's timer counts first; the players act
/// and move, a section due opens (its wall), and the camera follows them; then the others begin
/// their tick, take the blows and the grabs of the tick where they stand, decide, and move; the
/// round's script brings who comes.
pub const pipeline = [_]System{
    .{ .name = "timer", .run = script.timer },
    .{ .name = "commands", .run = commands },
    .{ .name = "control", .run = control },
    .{ .name = "players_move", .run = playersMove },
    .{ .name = "section", .run = script.opening },
    .{ .name = "camera", .run = camera },
    .{ .name = "begin", .run = begin },
    .{ .name = "hits", .run = hits },
    .{ .name = "grabs", .run = grabs },
    .{ .name = "ai", .run = ai },
    .{ .name = "movement", .run = movement },
    .{ .name = "pickups", .run = pickups },
    .{ .name = "script", .run = script.run },
    .{ .name = "animation", .run = animation },
    .{ .name = "sounds", .run = sounds },
    .{ .name = "draw_list", .run = draw_list.build },
};

/// One logic tick of `world`, with the pads `in`; its output in `out`.
pub fn run(world: *World, kinds: *const Kinds, rng: *random.Random, in: Input, out: *Output) void {
    runRound(world, kinds, rng, in, out, null);
}

/// The draw list of the world as it stands, with no tick: each entity on the frame it is on
/// (a round's set-up, whose picture shows its entities before they first move). No shadows: they
/// come with play (the original makes them in its play's mode only).
pub fn picture(t: *Tick) void {
    const kinds = t.kinds;
    defer t.kinds = kinds;
    var no_shadows = kinds.*;
    no_shadows.shadow = null;
    t.kinds = &no_shadows;
    t.out.begin();
    for (&t.world.entities, 0..) |*e, i| {
        if (!e.alive() or e.flags.hidden) continue;
        const index = e.animation.index orelse continue;
        const k = t.kindOf(e);
        const step = k.definition.animations[index].frames[e.animation.frame];
        t.out.shown[i] = .{ .frame = k.frames[index][e.animation.frame], .mirrored = e.facingLeft() != step.flip };
    }
    draw_list.build(t);
}

/// One logic tick of a round's world, which follows the round's script `plan` (null: none).
pub fn runRound(world: *World, kinds: *const Kinds, rng: *random.Random, in: Input, out: *Output, plan: ?*const script.Plan) void {
    out.begin();
    var t: Tick = .{ .world = world, .kinds = kinds, .random = rng, .out = out, .input = in, .plan = plan };
    inline for (pipeline) |s| s.run(&t);
    world.tick +%= 1;
}

// Input to commands -------------------------------------------------------------------------------

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
            .first = @bitCast(first_new),
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

// Player control ----------------------------------------------------------------------------------

fn control(t: *Tick) void {
    for (t.world.players) |p| {
        const h = p.entity orelse continue;
        t.control(h, p.command);
    }
}

// The AI ------------------------------------------------------------------------------------------

/// The others' ticks begin (a state entered at the last tick sets itself up), before the blows.
fn begin(t: *Tick) void {
    var buf: [capacity]u8 = undefined;
    for (t.world.updateOrder(&buf)) |i| {
        const h = t.world.handleAt(i) orelse continue;
        if (t.world.playerOf(h) != null) continue;
        t.begin(h);
    }
}

fn ai(t: *Tick) void {
    var buf: [capacity]u8 = undefined;
    for (t.world.updateOrder(&buf)) |i| {
        const h = t.world.handleAt(i) orelse continue;
        if (t.world.playerOf(h) != null) continue;
        t.think(h);
    }
}

// Movement and gravity ----------------------------------------------------------------------------

/// The depths of the ground, in whole pixels: an entity drawn is kept on them (the original
/// keeps them where it orders its drawing).
pub const ground_depths: struct { near: i32, far: i32 } = .{ .far = 0, .near = 240 };

/// The entities the players play move, in their turn.
fn playersMove(t: *Tick) void {
    for (t.world.players) |p| {
        const h = p.entity orelse continue;
        move(t, h);
    }
}

/// The other entities move, in the world's order.
fn movement(t: *Tick) void {
    var buf: [capacity]u8 = undefined;
    for (t.world.updateOrder(&buf)) |i| {
        const h = t.world.handleAt(i) orelse continue;
        if (t.world.playerOf(h) != null) continue;
        move(t, h);
    }
}

/// An entity moves by its speed, unless it is held (its holder places it) or still. In the air,
/// its behaviour's `fall` decides (`Tick.fall`); by default it lands when it has come down to
/// the ground (`Tick.land`), and otherwise its gravity adds to its speed in height. A drawn
/// entity's depth is kept on the ground's depths, its fraction kept.
fn move(t: *Tick, h: Handle) void {
    const e = t.world.get(h) orelse return;
    e.flags.landed = false;
    if (e.holder != null or e.flags.still) return;
    e.position = e.position.add(e.velocity);
    if (e.flags.airborne) t.fall(h);
    if (t.world.get(h)) |still| if (!still.flags.hidden) keepOnGround(still);
}

fn keepOnGround(e: *Entity) void {
    const d = e.position.depth.whole();
    const kept = std.math.clamp(d, ground_depths.far, ground_depths.near);
    if (kept != d) e.position.depth = .parts(@intCast(kept), e.position.depth.frac());
}

// Hits --------------------------------------------------------------------------------------------

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

/// Each entity whose blow is under way (`Tick.power`) and whose frame has an attack box strikes
/// each entity whose body box it meets, of a team its blows land on: the struck entity's
/// behaviour takes the blow or not (`Tick.struck`: by default, its damage at once); a blow
/// taken is told to the striker (`blowLanded`) and asks for the move's hit sound. An attack box
/// without a blow under way is a reach, which the grabs answer.
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
            const damage = t.power(a);
            if (damage == 0) break;
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
                .damage = damage,
                .reaction = m.reaction,
                .push = .{ .x = Fixed.of(m.push_x).times(away), .height = .of(m.push_height) },
            };
            if (!t.struck(th, blow)) continue;
            t.blowLanded(ah, th);
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

// Grabs -------------------------------------------------------------------------------------------

/// An entity whose behaviour asks to grab, holding nothing and held by nothing, with a reach (an
/// attack box while no blow is under way), holds the first entity (in the world's order) whose
/// body its reach meets, of a team its blows land on, free too, and whose behaviour lets it
/// (`grabbable`). The holder's behaviour places the one it holds; a grab ends when either goes
/// (`World.remove`) or a behaviour lets go.
fn grabs(t: *Tick) void {
    var buf: [capacity]u8 = undefined;
    const order = t.world.updateOrder(&buf);
    for (order) |i| {
        const h = t.world.handleAt(i) orelse continue;
        const e = t.world.get(h).?;
        if (!e.flags.wants_grab) continue;
        e.flags.wants_grab = false;
        if (e.holding != null or e.holder != null) continue;
        const reach = e.boxes.attack orelse continue;
        if (t.power(e) != 0) continue;
        for (order) |j| {
            if (j == i) continue;
            const oh = t.world.handleAt(j) orelse continue;
            const o = t.world.get(oh).?;
            if (o.holder != null or o.holding != null or !blowsLand(e.team, o.team)) continue;
            const ob = o.boxes.body orelse continue;
            if (!meet(e, &t.kindOf(e).definition.boxes[reach], o, &t.kindOf(o).definition.boxes[ob])) continue;
            if (!t.grabbable(oh, h)) continue;
            e.holding = oh;
            o.holder = h;
            t.grabbed(h, oh);
            break;
        }
    }
}

// Pick-ups ----------------------------------------------------------------------------------------

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

// The camera --------------------------------------------------------------------------------------

/// How the camera follows the players (the original's, measured in sor-remaster; TODO(PLAN item
/// 13): the round's camera from its content): a player drawn past the view's middle band moves
/// it by as much, at most `follow_most` a tick; the players are kept `margin` pixels inside the
/// view's sides (but in a hold) and on the walkable depths.
pub const following = struct {
    pub const band_from = 144;
    pub const band_to = 176;
    pub const follow_most = 3;
    pub const margin = 32;
    pub const width = 320;
    pub const depth_from = 2;
    pub const depth_to = 112;
};

/// How the camera shakes (`Tick.shake`; the original's, measured in sor-remaster; TODO(PLAN item
/// 13): from the round's camera's content): for `ticks` ticks it moves `by` pixels down at an odd
/// tick left and back up at an even one.
pub const shaking = struct {
    pub const ticks = 8;
    pub const by = 3;
};

/// The camera follows the players across (when it `follows`), from where the last tick drew
/// them, never going back (its limit on the left follows it), and stays within its limits (but
/// while it shakes); then the players are kept inside its view. While the special attack runs
/// it (`Camera.run`), it neither follows nor holds the players. Its limit on the right is the
/// round's script's wall (script.zig).
fn camera(t: *Tick) void {
    const c = &t.world.camera;
    if (c.run) |*r| switch (r.state) {
        // At the call's tick it follows as before, but its limit is already the run's.
        .called => {
            c.x_min = r.limit;
            r.state = .back;
        },
        .back => {
            c.x = c.x.sub(r.speed).max(r.limit);
            return noteDrawn(t);
        },
        .ahead => {
            c.x = c.x.add(r.speed).min(c.x_max);
            if (c.x.whole() >= r.from.whole()) c.run = null;
            return noteDrawn(t);
        },
    };
    if (c.follows) {
        if (c.run == null) c.x_min = c.x;
        // Where a player was drawn, in whole pixels on the screen.
        var speed: i32 = 0;
        for (c.drawn) |d| {
            const x = d orelse continue;
            const on_screen = x.whole() - c.x.whole();
            if (on_screen < following.band_from) {
                speed = on_screen - following.band_from;
            } else if (on_screen >= following.band_to) {
                speed = on_screen - following.band_to;
            }
        }
        const most = following.follow_most;
        c.x = c.x.add(.pixels(std.math.clamp(speed, -most, most)));
    }
    c.x = c.x.clamp(c.x_min, c.x_max);
    if (c.shake != 0) {
        c.shake -= 1;
        c.y = c.y.add(.pixels(if (c.shake & 1 != 0) shaking.by else -shaking.by));
    } else c.y = c.y.clamp(c.y_min, c.y_max);
    if (!c.follows) return;
    for (t.world.players) |p| {
        const e = t.world.get(p.entity orelse continue) orelse continue;
        if (e.flags.hidden) continue;
        if (e.holding == null and e.holder == null) {
            const left = c.x.add(.pixels(following.margin));
            const right = left.add(.pixels(following.width - 2 * following.margin));
            e.position.x = e.position.x.clamp(left, right);
        }
        e.position.depth = e.position.depth.clamp(.pixels(following.depth_from), .pixels(following.depth_to));
    }
    noteDrawn(t);
}

/// Where the players are drawn at this tick, for the camera's next (a player waiting to continue
/// is not drawn).
fn noteDrawn(t: *Tick) void {
    for (t.world.players, &t.world.camera.drawn) |p, *d| {
        d.* = null;
        const e = t.world.get(p.entity orelse continue) orelse continue;
        if (e.flags.hidden) continue;
        d.* = e.position.x;
    }
}

// Animation ---------------------------------------------------------------------------------------

/// Each entity shows the frame it is on at this tick (noted in the output, which the draw list
/// draws), and that frame's boxes are those in use from now on; at the frame's first tick its
/// sound is asked for; then the frame's ticks count down, and when they run out the next frame
/// comes for the next tick: after the last, the first again (a looping animation) or the last
/// stays, and the animation is done. So a frame shows for its ticks from the tick its animation
/// starts, and the logic of a tick sees the frame the tick before showed, as in the original,
/// where an object's frame advances after it is drawn. A hidden entity is not drawn: its frame
/// stays and it has no boxes. An entity whose behaviour drives its animation (the players,
/// behaviours.zig) has its frame noted only: its behaviour advanced it and set its boxes, before
/// the blows of the tick.
fn animation(t: *Tick) void {
    for (&t.world.entities, 0..) |*e, i| {
        if (!e.alive()) continue;
        const index = e.animation.index orelse continue;
        const k = t.kindOf(e);
        const an = k.definition.animations[index];
        const step = an.frames[e.animation.frame];
        const mirrored = e.facingLeft() != step.flip;
        if (behaviours.drivesAnimation(&e.mind)) {
            t.out.shown[i] = .{ .frame = k.frames[index][e.animation.frame], .mirrored = mirrored };
            continue;
        }
        // Hidden, it is not drawn: as the original's, its frame stays and it has no boxes.
        if (e.flags.hidden) {
            e.boxes = .{};
            continue;
        }
        t.out.shown[i] = .{ .frame = k.frames[index][e.animation.frame], .mirrored = mirrored };
        e.boxes = .{ .body = step.body, .attack = step.attack, .mirrored = mirrored };
        if (e.animation.left == step.ticks and !(e.animation.done and !an.loop)) {
            if (step.sound) |sound| t.sound(sound, t.world.handleAt(i));
        }
        if (e.animation.paused) continue;
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
        e.animation.left = e.animation.pace orelse an.frames[e.animation.frame].ticks;
    }
}

// Sound events ------------------------------------------------------------------------------------

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
