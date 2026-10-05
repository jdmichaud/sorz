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
const lives = @import("lives.zig");

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
/// and move, a section due opens (its wall), and the camera follows them; the players' blows and
/// grabs on each other land; then the others take their turns one after the other (each begins
/// its tick, takes the blows and the grabs of the tick where it stands and decides), and move;
/// the round's script brings who comes. Where the players are drawn at the tick's end is what the
/// camera follows at the next (`noteDrawn`).
pub const pipeline = [_]System{
    .{ .name = "timer", .run = script.timer },
    .{ .name = "commands", .run = commands },
    .{ .name = "control", .run = control },
    .{ .name = "players_move", .run = playersMove },
    .{ .name = "join", .run = joining },
    .{ .name = "section", .run = script.opening },
    .{ .name = "camera", .run = camera },
    .{ .name = "between_players", .run = betweenPlayers },
    .{ .name = "turns", .run = turns },
    .{ .name = "movement", .run = movement },
    .{ .name = "pickups", .run = pickups },
    .{ .name = "script", .run = script.run },
    .{ .name = "animation", .run = animation },
    .{ .name = "sounds", .run = sounds },
    .{ .name = "draw_list", .run = draw_list.build },
    .{ .name = "drawn", .run = noteDrawn },
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
        t.out.new_frames[i] = true;
    }
    draw_list.build(t);
}

/// The draw list of a world in play as its last tick left it, made again without a tick (a game
/// loaded from another's form: its picture right from its first frame): each entity on the frame
/// it is on, its shadow with it; the world itself unchanged. The list shows at once.
pub fn redraw(t: *Tick) void {
    t.out.* = .{};
    for (&t.world.entities, 0..) |*e, i| {
        if (!e.alive() or e.flags.hidden) continue;
        const index = e.animation.index orelse continue;
        const k = t.kindOf(e);
        const step = k.definition.animations[index].frames[e.animation.frame];
        t.out.shown[i] = .{ .frame = k.frames[index][e.animation.frame], .mirrored = e.facingLeft() != step.flip };
    }
    draw_list.listOf(t, false);
    t.out.latch();
}

/// One logic tick of a round's world, which follows the round's script `plan` (null: none).
pub fn runRound(world: *World, kinds: *const Kinds, rng: *random.Random, in: Input, out: *Output, plan: ?*const script.Plan) void {
    out.begin();
    var t: Tick = .{ .world = world, .kinds = kinds, .random = rng, .out = out, .input = in, .plan = plan };
    inline for (pipeline) |s| s.run(&t);
    world.tick +%= 1;
}

// A player joining ------------------------------------------------------------------------------

/// A player joining the game under way at this tick (`Input.join`: the round's PRESS 2UP START,
/// network play's second player): its first life drops in after the players' turns and before
/// the camera's and the others' (the original's join comes before its objects' update, and its
/// joining player's first update sets it up without moving it), so that the camera keeps it in
/// its view and the enemies it knocks back move away at this tick.
fn joining(t: *Tick) void {
    const j = t.input.join orelse return;
    _ = lives.join(t, j.player, j.kind, j.lives);
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
            .last = @bitCast(last_new),
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

// The others' turns -------------------------------------------------------------------------------

/// The players' blows on each other land (the original's two players strike each other), then
/// their grabs of each other.
fn betweenPlayers(t: *Tick) void {
    for (t.world.players) |p| {
        const ah = p.entity orelse continue;
        for (t.world.players) |q| {
            const th = q.entity orelse continue;
            if (!th.eql(ah)) blow(t, ah, th);
        }
    }
    for (t.world.players) |p| {
        const gh = p.entity orelse continue;
        for (t.world.players) |q| {
            const th = q.entity orelse continue;
            if (!th.eql(gh) and grab(t, gh, th)) break;
        }
    }
}

/// The others' turns, in the world's order, as the original runs its objects one after the
/// other, each through its whole tick: the entity's tick begins (a state entered at the last tick
/// sets itself up); the blows that meet it land (`blowsOn`); a player asking to grab it holds it,
/// before its own blows land on the players (the original looks at a player's reach before its
/// blow); and it decides. What each draws from the random generator is thus drawn in the
/// original's order. An entity that appears during the turns in a later place has its turn in
/// the same tick, as in the original. Through the turns, the players' boxes stay where the
/// players' own turn left them (`Boxes.at`, `playersMove`); their asks to grab end with them.
fn turns(t: *Tick) void {
    for (0..capacity) |i| {
        const h = t.world.handleAt(i) orelse continue;
        if (t.world.playerOf(h) != null) continue;
        t.begin(h);
        blowsOn(t, h);
        grabbedByPlayers(t, h);
        blowsOnPlayers(t, h);
        if (t.world.get(h) != null) t.think(h);
    }
    for (t.world.players) |p| {
        const h = p.entity orelse continue;
        const e = t.world.get(h) orelse continue;
        e.flags.wants_grab = false;
        e.boxes.at = null;
    }
}

// Movement and gravity ----------------------------------------------------------------------------

/// The depths of the ground, in whole pixels: an entity drawn is kept on them (the original
/// keeps them where it orders its drawing).
pub const ground_depths: struct { near: i32, far: i32 } = .{ .far = 0, .near = 240 };

/// The entities the players play move, in their turn; one that moved into a solid thing is
/// kept out of it (`Tick.keptOut`). Their boxes stay where their turn left them through the
/// others' turns (`Boxes.at`), before the camera keeps them in its view: the original's players
/// set their boxes in the world at the end of their own turn.
fn playersMove(t: *Tick) void {
    for (t.world.players) |p| {
        const h = p.entity orelse continue;
        move(t, h);
        const e = t.world.get(h) orelse continue;
        if (e.holder == null) _ = t.keptOut(h);
        e.boxes.at = e.position;
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

/// An entity moves by its speed (but in depth when it `keeps_depth`, and in height on the
/// ground), unless it is held (its holder places it, or it follows its holder: `Tick.follow`) or
/// still. In the air, its behaviour's `fall` decides (`Tick.fall`); by default it lands when it
/// has come down to the ground (`Tick.land`), and otherwise its gravity adds to its speed in
/// height. A drawn entity's depth is kept on the ground's depths, its fraction kept.
fn move(t: *Tick, h: Handle) void {
    const e = t.world.get(h) orelse return;
    e.flags.landed = false;
    if (e.holder != null) return t.follow(h);
    if (e.flags.still) return;
    const was = e.position;
    e.position = e.position.add(e.velocity);
    if (e.flags.keeps_depth) e.position.depth = was.depth;
    if (!e.flags.airborne) e.position.height = was.height;
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

/// The blows that meet `x` at its turn land: the missiles' first (the original's enemies look at
/// the things thrown before the players), then the blows under way of the others, each in the
/// world's order.
fn blowsOn(t: *Tick, xh: Handle) void {
    var buf: [capacity]u8 = undefined;
    const order = t.world.updateOrder(&buf);
    for (order) |i| {
        const ah = t.world.handleAt(i) orelse continue;
        if (ah.eql(xh)) continue;
        if (t.world.get(ah).?.missile != null) missileOn(t, ah, xh);
    }
    for (order) |i| {
        const ah = t.world.handleAt(i) orelse continue;
        if (ah.eql(xh)) continue;
        if (t.world.get(ah).?.missile == null) blow(t, ah, xh);
    }
}

/// `x`'s blow under way, or `x` thrown or flying as a missile, meets the players: but not a
/// player whose blow or reach meets `x`'s body. The original looks at the player's box first:
/// then the player's blow, its grab, or neither (a reach that cannot grab: a weapon in hand, `x`
/// too high) is the tick's meeting of the two, and `x`'s own blow is not looked at.
fn blowsOnPlayers(t: *Tick, xh: Handle) void {
    for (t.world.players) |p| {
        const th = p.entity orelse continue;
        const x = t.world.get(xh) orelse return;
        if (reachesBody(t, th, x)) continue;
        if (x.missile != null) missileOn(t, xh, th) else blow(t, xh, th);
    }
}

/// Whether the attack box of player entity `ph` (a blow's or a reach) meets `x`'s body.
fn reachesBody(t: *Tick, ph: Handle, x: *const Entity) bool {
    const p = t.world.get(ph) orelse return false;
    const reach = p.boxes.attack orelse return false;
    const body = x.boxes.body orelse return false;
    return meet(p, &t.kindOf(p).definition.boxes[reach], x, &t.kindOf(x).definition.boxes[body]);
}

/// `a`'s blow under way (`Tick.power`), when its frame has an attack box, strikes `target` when
/// the box meets its body and `a`'s team's blows land on its team: the target's behaviour takes
/// the blow or not (`Tick.struck`: by default, its damage at once); a blow taken is told to the
/// striker (`blowLanded`) and, on a fighter, asks for the move's hit sound (a breakable sounds
/// its own). An attack box without a blow under way is a reach, which the grabs answer.
fn blow(t: *Tick, ah: Handle, th: Handle) void {
    const a = t.world.get(ah) orelse return;
    const attack = a.boxes.attack orelse return;
    const move_index = a.move orelse return;
    const damage = t.power(a);
    if (damage == 0) return;
    const target = t.world.get(th) orelse return;
    const body = target.boxes.body orelse return;
    if (!blowsLand(a.team, target.team)) return;
    const ak = t.kindOf(a);
    if (!meet(a, &ak.definition.boxes[attack], target, &t.kindOf(target).definition.boxes[body])) return;
    const m = ak.definition.moves[move_index];
    const away: i32 = switch (target.position.x.order(a.position.x)) {
        .lt => -1,
        .gt => 1,
        .eq => a.facing.sign(),
    };
    const b: tick_mod.Blow = .{
        .attacker = ah,
        .damage = damage,
        .reaction = m.reaction,
        .push = .{ .x = Fixed.of(m.push_x).times(away), .height = .of(m.push_height) },
    };
    if (!t.struck(th, b)) return;
    t.blowLanded(ah, th);
    const fighter = switch (t.kindOf(target).family()) {
        .player, .enemy, .boss => true,
        else => false,
    };
    if (fighter) if (m.hit_sound) |snd| t.sound(snd, ah);
}

/// A missile (`Missile`: a body thrown, a weapon swung or thrown) strikes with its attack box
/// `target` when it meets its body and is of a team the blows of the one who threw or swings it
/// land on (a player's on the enemies and the breakables; with `on_players`, the players but its
/// thrower too): the struck one's behaviour takes the blow, its damage the missile's, knocking
/// down.
fn missileOn(t: *Tick, ah: Handle, th: Handle) void {
    const a = t.world.get(ah) orelse return;
    const m = a.missile orelse return;
    const attack = a.boxes.attack orelse return;
    if (th.eql(m.by)) return;
    const target = t.world.get(th) orelse return;
    const body = target.boxes.body orelse return;
    const by_team = if (t.world.getConst(m.by)) |b| b.team else a.team;
    const lands = switch (target.team) {
        .player => m.on_players or by_team == .enemy,
        .enemy, .neutral => by_team == .player,
    };
    if (!lands) return;
    if (!meet(a, &t.kindOf(a).definition.boxes[attack], target, &t.kindOf(target).definition.boxes[body])) return;
    const b: tick_mod.Blow = .{ .attacker = ah, .damage = m.damage, .reaction = .knock_down, .push = .zero, .missile = true };
    if (!t.struck(th, b)) return;
    t.blowLanded(ah, th);
}

/// Whether box `ab` of `a` meets box `bb` of `b`: on each axis, their spans from where the
/// entities' boxes stand (their places, but `Boxes.at`; whole pixels) overlap or touch.
pub fn meet(a: *const Entity, ab: *const content_entity.Box, b: *const Entity, bb: *const content_entity.Box) bool {
    const pa = a.boxes.at orelse a.position;
    const pb = b.boxes.at orelse b.position;
    return spansMeet(pa.x.whole(), ab.across(a.boxes.mirrored), pb.x.whole(), bb.across(b.boxes.mirrored)) and
        spansMeet(pa.depth.whole(), ab.depth, pb.depth.whole(), bb.depth) and
        spansMeet(pa.height.whole(), ab.upDown(a.boxes.mirrored), pb.height.whole(), bb.upDown(b.boxes.mirrored));
}

fn spansMeet(pa: i32, sa: content_entity.Span, pb: i32, sb: content_entity.Span) bool {
    return pa + sa.from <= pb + sb.to and pb + sb.from <= pa + sa.to;
}

// Grabs -------------------------------------------------------------------------------------------

/// The first player (in the world's order) asking to grab `x` whose reach meets it holds it.
fn grabbedByPlayers(t: *Tick, xh: Handle) void {
    for (t.world.players) |p| {
        const gh = p.entity orelse continue;
        if (grab(t, gh, xh)) return;
    }
}

/// An entity whose behaviour asks to grab, holding nothing and held by nothing, with a reach (an
/// attack box while no blow is under way), holds `target` when its reach meets its body, it is
/// of a team its blows land on, free too, and its behaviour lets it (`grabbable`). The holder's
/// behaviour places the one it holds; a grab ends when either goes (`World.remove`) or a
/// behaviour lets go.
fn grab(t: *Tick, gh: Handle, th: Handle) bool {
    const g = t.world.get(gh) orelse return false;
    if (!g.flags.wants_grab) return false;
    if (g.holding != null or g.holder != null) return false;
    const reach = g.boxes.attack orelse return false;
    if (t.power(g) != 0) return false;
    const o = t.world.get(th) orelse return false;
    if (o.holder != null or o.holding != null or !blowsLand(g.team, o.team)) return false;
    const ob = o.boxes.body orelse return false;
    if (!meet(g, &t.kindOf(g).definition.boxes[reach], o, &t.kindOf(o).definition.boxes[ob])) return false;
    if (!t.grabbable(th, gh)) return false;
    g.holding = th;
    o.holder = gh;
    t.grabbed(gh, th);
    return true;
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

/// The camera follows the players across (when it `follows`, by its rules: `Camera.Rules`),
/// from where the last tick drew them, never going back (its limit on the left follows it), and
/// stays within its limits (but while it shakes: `shake_by` pixels down at an odd tick left and
/// back up at an even one); then the players are kept inside its view. While the special attack
/// runs it (`Camera.run`), it neither follows nor holds the players. Its limit on the right is the
/// round's script's wall (script.zig).
fn camera(t: *Tick) void {
    const c = &t.world.camera;
    c.prev_x = c.x;
    if (c.run) |*r| switch (r.state) {
        // At the call's tick it follows as before, but its limit is already the run's.
        .called => {
            c.x_min = r.limit;
            r.state = .back;
        },
        .back => {
            c.x = c.x.sub(r.speed).max(r.limit);
            return;
        },
        .ahead => {
            c.x = c.x.add(r.speed).min(c.x_max);
            if (c.x.whole() >= r.from.whole()) c.run = null;
            return;
        },
    };
    if (c.follows) |rules| {
        if (c.run == null) c.x_min = c.x;
        // Where a player was drawn, in whole pixels on the screen.
        var speed: i32 = 0;
        for (c.drawn) |d| {
            const x = d orelse continue;
            const on_screen = x.whole() - c.x.whole();
            if (on_screen < rules.band[0]) {
                speed = on_screen - rules.band[0];
            } else if (on_screen >= rules.band[1]) {
                speed = on_screen - rules.band[1];
            }
        }
        c.x = c.x.add(.pixels(std.math.clamp(speed, -rules.most, rules.most)));
    }
    c.x = c.x.clamp(c.x_min, c.x_max);
    if (c.shake != 0) {
        c.shake -= 1;
        const by: i32 = if (c.follows) |rules| rules.shake_by else 0;
        c.y = c.y.add(.pixels(if (c.shake & 1 != 0) by else -by));
    } else c.y = c.y.clamp(c.y_min, c.y_max);
    const rules = c.follows orelse return;
    for (t.world.players) |p| {
        const e = t.world.get(p.entity orelse continue) orelse continue;
        if (e.holding == null and e.holder == null) {
            const left = c.x.whole();
            e.position.x = keptWithin(e.position.x, left + rules.kept_x[0], left + rules.kept_x[1]);
        }
        e.position.depth = keptWithin(e.position.depth, rules.kept_depth[0], rules.kept_depth[1]);
    }
}

/// `v` kept within whole pixels `from` to `to`, as the original keeps its players: its whole
/// pixels compared and set, its fraction kept.
fn keptWithin(v: Fixed, from: i32, to: i32) Fixed {
    const w = v.whole();
    if (w < from) return .parts(@intCast(from), v.frac());
    if (w > to) return .parts(@intCast(to), v.frac());
    return v;
}

/// Where the players are drawn at this tick's end, after the others' turns (one may have moved a
/// player: a hold, a throw), for the camera's next, as the original's camera reads where its
/// players were drawn (a player waiting to continue is not drawn).
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
        if (e.animation.left == step.ticks) t.out.new_frames[i] = true;
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

/// The tick's sounds go out in the order they were asked for, each in the half of the logic tick
/// that asked for it: the players' in the first, the others' in the second (the frame between
/// them takes the first's). A sound asked for twice in a half is asked for once, as the
/// original's sound queue holds a request once until the driver takes it; asked for in both
/// halves, it is asked for twice.
fn sounds(t: *Tick) void {
    const list = &t.out.sounds;
    var n: usize = 0;
    for (list.items[0..list.len]) |s| {
        var x = s;
        x.first = if (s.by) |h| t.world.playerOf(h) != null else false;
        for (list.items[0..n]) |kept| {
            if (kept.first == x.first and std.mem.eql(u8, kept.name, x.name)) break;
        } else {
            list.items[n] = x;
            n += 1;
        }
    }
    list.len = n;
}

test "a sound asked for in both halves of a tick goes out twice; twice in a half, once" {
    var w: World = .{};
    const hero: Handle = .{ .index = 0, .generation = 1 };
    const punk: Handle = .{ .index = 9, .generation = 1 };
    w.players[0].entity = hero;
    var kinds: Kinds = undefined;
    var rng: random.Random = .{};
    var out: Output = .{};
    var t: Tick = .{ .world = &w, .kinds = &kinds, .random = &rng, .out = &out };
    t.sound("heavy fall", hero);
    t.sound("heavy fall", punk);
    t.sound("heavy fall", hero);
    t.sound("heavy fall", null);
    sounds(&t);
    const s = out.sounds.slice();
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expect(s[0].first and s[0].by.?.eql(hero));
    try std.testing.expect(!s[1].first and s[1].by.?.eql(punk));
}
