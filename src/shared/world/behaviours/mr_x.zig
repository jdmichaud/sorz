//! Round 8's boss, Mr. X, standing with his machine gun. His code is his own, on round 3's boss's
//! helpers (his rise and fall, his target, his reach); his states, as the traces name them (the
//! original's, in its order):
//! - `appear`: his first tick (the status bar shows him, his health and power by the level), and
//!   each time he gets up: on his feet a few ticks, facing his target; then he sizes it up;
//! - `walk`: a new target, then he sizes it up;
//! - `size_up`: a while, facing his target: near it across he closes in (`close`); his time out,
//!   a burst (`burst`); off the screen's middle, he closes in or approaches at random;
//! - `approach`: across at his target, in depth away from its part of the screen; at the
//!   screen's edge he sizes it up again; at reach, he dashes (`dash`);
//! - `close`: at his target, along the ways it is far; at reach, he dashes;
//! - `dash`: fast at his target with his gun, slowing (a player his gun meets is knocked down);
//!   then he backs off, or, in the screen's middle, now and then a burst;
//! - `burst`: up to the floor's top, his gun raised, aimed his target's way, fired: a shot and a
//!   cartridge flying the other way at every other frame (mr_x_shot.zig, mr_x_cartridge.zig);
//!   then he approaches;
//! - `back_off`: away from his target, facing it, a while or to the screen's edge;
//! - a player's blow strikes him (`struck`, shaken), or knocks him away (`knocked_away`: he
//!   flies, falls, lies, gets up), a blow that knocks down, a thing thrown, a player's new life;
//! - `grabbed` by a player: in front of it, its knees strike him (the last knocks him away), its
//!   throw throws him (`thrown`), its vault holds him from behind (`held_behind`), whence it
//!   slams him (`slammed`);
//! - `defeated`: his health gone, the boss is beaten: he flies away spilling cartridges, falls,
//!   bounces, lies, rises groaning, drops shaking, gives his points; then the round is won.
//! His tick runs his state's code to its look at what met him (the original's hit test) as it
//! begins, and the rest after the blows of the tick. His numbers, animations and sounds are his
//! definition's (`entities/mr_x.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const systems = @import("../systems.zig");
const world_mod = @import("../world.zig");
const boss_r3 = @import("boss_r3.zig");
const shot_mod = @import("mr_x_shot.zig");
const cartridge_mod = @import("mr_x_cartridge.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Entity = entity.Entity;
const Actor = tick.Actor(@This());

pub const State = enum {
    appear,
    walk,
    dash,
    size_up,
    approach,
    back_off,
    close,
    burst,
    struck,
    knocked_away,
    grabbed,
    held_behind,
    thrown,
    slammed,
    defeated,
};

/// What met him at this tick: a player's blow, a player's grab, a thing thrown.
pub const Hit = union(enum) {
    none,
    blow: struct { by: Handle, damage: i16, knocks_down: bool },
    grab: Handle,
    missile: Handle,
};

/// What his state does after its look at what met him, at the end of his tick.
const After = enum { none, face, move };

pub const Mind = struct {
    state: State = .appear,
    /// The step within his state.
    step: u8 = 0,
    /// The original's count of ticks, which his states share (his last fall's cartridges count
    /// on from what the state before left); the burst's second count.
    ticks: u16 = 0,
    period: u16 = 0,
    /// A way across (1 or -1: held from behind, thrown), or his last fall's sway in height.
    dir: i16 = 0,
    /// The holder's frame, or his gun's, seen last.
    seen: u8 = 0,
    /// His target, a player; the player holding him.
    target: ?Handle = null,
    holder: ?Handle = null,
    /// A shake's step across; the change of his speed across, and in height, a tick.
    shake: i16 = 0,
    accel: Fixed = .zero,
    gravity: Fixed = .zero,
    power: u8 = 0,
    /// Where he was drawn across (from the camera) at the last tick.
    drawn: i16 = 0,
    /// His holder let him go; a player's new life came.
    let_go: bool = false,
    entered: bool = false,
    /// This tick: what met him, whether his state looks for it, what it does after; whether his
    /// tick ended as it began.
    hit: Hit = .none,
    looks: bool = false,
    after: After = .none,
    ended: bool = false,
};

pub const Animation = enum { walk, raise, aim, dash, held_behind, thrown, knocked, struck };
pub const Sound = enum { hurt, thud, groan };

pub const Numbers = struct {
    walk_speed: Fixed,
    get_up_ticks: u16,
    get_up_frame: u8,
    size_up_ticks: u16,
    /// His reach: his target this near in depth and across (`close_near` closing in).
    reach_level: i16,
    reach_near: i16,
    close_within: i16,
    approach_depth: Fixed,
    depth_least: Fixed,
    depth_most: Fixed,
    /// The line his target was drawn above (from the screen's top) that sends him down.
    screen_top: i16,
    /// What he reads of his target before he has one (`Seen`).
    unseen_x: Fixed,
    unseen_depth: Fixed,
    unseen_left: u8,
    unseen_line: i16,
    /// The screen's edges (drawn across) he turns at.
    edge_left: i16,
    edge_right: i16,
    back_off_ticks: u16,
    close_near: i16,
    burst_depth: Fixed,
    burst_up: Fixed,
    raise_ticks: u16,
    raise_still: u16,
    burst_frames: u16,
    burst_period: u16,
    dash_speed: Fixed,
    dash_slowing: Fixed,
    dash_ticks: u16,
    dash_still: u16,
    dash_fire: u8,
    struck_ticks: u16,
    shake: i16,
    knock_away_slowing: Fixed,
    knock_away_up: Fixed,
    knock_away_x: Fixed,
    knocked_gravity: Fixed,
    falling_gravity: Fixed,
    bounce_above: Fixed,
    bounce_shift: u5,
    lie_ticks: u16,
    knocked_lie_ticks: u16,
    missile_damage: u8,
    grabbed_ticks: u16,
    grabbed_ahead: i16,
    grabbed_wait: u16,
    grabbed_hold: u16,
    held_ticks: u16,
    thrown_up: Fixed,
    thrown_gravity: Fixed,
    thrown_x: Fixed,
    thrown_slowing: Fixed,
    thrown_over: i16,
    thrown_down: Fixed,
    floor: i16,
    thrown_bounce: Fixed,
    thrown_damage: i16,
    thrown_slide: u16,
    slammed_frame: u8,
    slammed_ticks: u16,
    slammed_up: Fixed,
    slammed_gravity: Fixed,
    slammed_x: Fixed,
    slammed_slowing: Fixed,
    slammed_damage: i16,
    defeated_gravity: Fixed,
    defeated_x: Fixed,
    defeated_up: Fixed,
    defeated_falling: Fixed,
    defeated_most: Fixed,
    defeated_bounce: Fixed,
    defeated_bounce_gravity: Fixed,
    defeated_rest: Fixed,
    defeated_lie: u16,
    defeated_frame: u8,
    defeated_sway: i16,
    defeated_rise: u16,
    defeated_down: u16,
    points: u32,
    spill_every: u16,
    spill_height: u16,
    spill_spread: u16,
    spill_ahead: i16,
};

pub const Tables = struct {
    /// His health and power by the options' level.
    strength: [8]u8,
    /// The state a player's grab sends him to, by its request (boss_r3.zig's `request`);
    /// negative: none.
    grab_states: [12]i8,
    /// By the holder's character, his places from it by the holder's frame: rows of 4 (held
    /// from behind, slammed, thrown), across then in height.
    throw_x_axel: [12]i16,
    throw_height_axel: [12]i16,
    throw_x_adam: [12]i16,
    throw_height_adam: [12]i16,
    throw_x_blaze: [12]i16,
    throw_height_blaze: [12]i16,
};

pub const shot_kind = "mr_x_shot";
pub const cartridge_kind = "mr_x_cartridge";

/// His entry in the status bar's names and bars.
const bar_entry = 12;

// The hooks --------------------------------------------------------------------------------------

/// A player's new life knocks him away at his turn (his health left, not knocked away nor
/// grabbed already).
pub fn knockedBack(a: Actor) void {
    a.mind.entered = true;
}

/// A blow meets him only when his state looks at this tick, the first of the tick: a player's
/// while he was drawn in the screen's middle; a thing thrown.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    const m = a.mind;
    if (!m.looks or m.hit != .none) return false;
    if (blow.missile) {
        m.hit = .{ .missile = blow.attacker };
        return true;
    }
    if (m.drawn < -8 or m.drawn >= 328) return false;
    m.hit = .{ .blow = .{ .by = blow.attacker, .damage = blow.damage, .knocks_down = blow.reaction == .knock_down } };
    return true;
}

/// A player's grab takes him when his state looks at this tick (not held already), within his
/// height, when the grab's table sends him somewhere for the player's request.
pub fn grabbable(a: Actor, by: Handle) bool {
    const m = a.mind;
    if (!m.looks or m.hit != .none or m.state == .grabbed) return false;
    const holder = a.other(by) orelse return false;
    if (@abs(holder.position.height.whole() - a.entity.position.height.whole()) > 8) return false;
    if (a.tables().grab_states[boss_r3.request(holder)] < 0) return false;
    m.hit = .{ .grab = by };
    return true;
}

pub fn heldBy(a: Actor, holder: Handle) void {
    a.mind.holder = holder;
    a.mind.let_go = false;
}

/// His holder let him go: he breaks free at his turn.
pub fn letGoBy(a: Actor, holder: Handle) void {
    _ = holder;
    a.mind.let_go = true;
}

/// Taken up from a situation, `elapsed` ticks into his state: his first tick's set-up (his
/// health the situation's), his target; on his feet in his first state, his time counted on;
/// sizing up, standing.
pub fn takeUp(a: Actor, elapsed: u32) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const health = e.health;
    firstTick(a);
    e.health = health;
    // A target, but on his feet at his first state (he has none yet).
    if (m.state != .appear) chooseTarget(a);
    m.drawn = @intCast(e.position.x.whole() - a.tick.world.camera.x.whole());
    const ago: u16 = @intCast(@min(elapsed, std.math.maxInt(u16)));
    switch (m.state) {
        .appear => {
            a.pause(true);
            a.animate(.knocked);
            a.setFrame(n.get_up_frame);
            faceTarget(a);
            m.step = 2;
            m.ticks = n.get_up_ticks -| ago;
        },
        .size_up => {
            a.animate(.walk);
            a.pause(true);
            faceTarget(a);
            m.ticks = n.size_up_ticks -| ago;
        },
        else => {},
    }
}

// The tick ---------------------------------------------------------------------------------------

/// His tick until the blows are met: with no player fighting he stands still; a player's new
/// life knocks him away; then his state, to its look at what met him.
pub fn begin(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    e.flags.still = true;
    m.hit = .none;
    m.looks = false;
    m.after = .none;
    m.ended = false;
    if (!anyFighting(a)) {
        a.pause(true);
        m.ended = true;
        return;
    }
    if (m.entered) {
        m.entered = false;
        if (e.health > 0 and m.state != .knocked_away and m.state != .grabbed) {
            setState(a, .knocked_away);
            knockAway(a);
        }
    }
    switch (m.state) {
        .appear => appear(a),
        .walk => {
            chooseTarget(a);
            walk(a);
            m.ticks = a.numbers().size_up_ticks;
            a.pause(true);
            m.state = .size_up;
        },
        .dash => dash(a),
        .size_up => sizeUp(a),
        .approach => approach(a),
        .back_off => backOff(a),
        .close => close(a),
        .burst => burst(a),
        .struck => struck_(a),
        .knocked_away => knockedAway(a),
        .grabbed => grabbed(a),
        .held_behind => heldBehind(a),
        .thrown => thrown(a),
        .slammed => slammed(a),
        .defeated => defeated(a),
    }
}

/// His tick after the blows were met: what met him, then the rest of his state's tick.
pub fn think(a: Actor) void {
    const m = a.mind;
    if (!m.ended and m.looks) {
        if (m.state == .grabbed) grabbedMet(a) else hitCheck(a);
        switch (m.after) {
            .none => {},
            .face => faceTarget(a),
            .move => move(a),
        }
    }
    if (!a.entity.alive()) return;
    m.drawn = @intCast(a.entity.position.x.whole() - a.tick.world.camera.x.whole());
}

/// Its look at what met him, and what it does after.
fn looks(a: Actor, after: After) void {
    a.mind.looks = true;
    a.mind.after = after;
}

fn anyFighting(a: Actor) bool {
    for (a.tick.world.players) |p| {
        const e = a.tick.world.getConst(p.entity orelse continue) orelse continue;
        if (e.mind == .player) return true;
    }
    return false;
}

fn setState(a: Actor, state: State) void {
    a.mind.step = 0;
    a.mind.state = state;
}

// His moves ----------------------------------------------------------------------------------------

fn move(a: Actor) void {
    const e = a.entity;
    e.position = e.position.add(e.velocity);
}

fn target(a: Actor) ?*Entity {
    return a.other(a.mind.target orelse return null);
}

/// What he reads of his target: its place, the way it faces, the line it was drawn on at the last
/// tick. Before he has one (his first states), the original reads them from the start of its
/// memory, its program's first words: his definition's `unseen_*` (`unseen_line` from the
/// screen's top).
const Seen = struct { x: Fixed, depth: Fixed, left: bool, line: i16 };

fn seen(a: Actor) Seen {
    const n = a.numbers();
    const t = target(a) orelse return .{ .x = n.unseen_x, .depth = n.unseen_depth, .left = n.unseen_left != 0, .line = n.unseen_line };
    const k = a.tick.world.playerOf(a.mind.target.?);
    const line = if (k) |i| a.tick.world.camera.drawn_lines[i] else null;
    return .{ .x = t.position.x, .depth = t.position.depth, .left = t.facingLeft(), .line = line orelse n.unseen_line };
}

/// His target: player 1 alone; with player 2 alone, player 2; with both, the nearer across
/// (player 2 at a tie).
fn chooseTarget(a: Actor) void {
    const w = a.tick.world;
    const p1 = fightingPlayer(a, 0);
    const p2 = fightingPlayer(a, 1);
    var second = false;
    if (p2) |h2| {
        if (p1) |h1| {
            const x = a.entity.position.x;
            const near_1 = w.getConst(h1).?.position.x.sub(x).abs();
            const near_2 = w.getConst(h2).?.position.x.sub(x).abs();
            second = !near_1.lessThan(near_2);
        } else second = true;
    }
    a.mind.target = if (second) p2 else p1 orelse p2;
}

fn fightingPlayer(a: Actor, k: usize) ?Handle {
    const h = a.tick.world.players[k].entity orelse return null;
    const e = a.tick.world.getConst(h) orelse return null;
    return if (e.mind == .player) h else null;
}

/// The way to his target, across and in depth (1 or -1; 1 when level).
fn direction(a: Actor) struct { x: i32, depth: i32 } {
    const t = seen(a);
    const e = a.entity;
    return .{
        .x = if (t.x.lessThan(e.position.x)) -1 else 1,
        .depth = if (t.depth.lessThan(e.position.depth)) -1 else 1,
    };
}

/// How far his target is (whole pixels), in depth and across, and whether at least the limits.
const Reach = struct { far_depth: bool, far_x: bool, depth: i32, x: i32 };

fn reach(a: Actor, level: i16, near: i16) Reach {
    const t = seen(a);
    const e = a.entity;
    const dd: i32 = @intCast(@abs(t.depth.whole() - e.position.depth.whole()));
    const dx: i32 = @intCast(@abs(t.x.whole() - e.position.x.whole()));
    return .{ .far_depth = dd >= level, .far_x = dx >= near, .depth = dd, .x = dx };
}

/// His speeds turned toward his target, across and in depth.
fn aim(a: Actor) void {
    const d = direction(a);
    const v = &a.entity.velocity;
    if ((v.x.raw < 0) != (d.x < 0)) v.x = v.x.neg();
    if ((v.depth.raw < 0) != (d.depth < 0)) v.depth = v.depth.neg();
}

/// He faces his target (to the right when it is level).
fn faceTarget(a: Actor) void {
    a.entity.facing = if (seen(a).x.lessThan(a.entity.position.x)) .left else .right;
}

/// Walking: animated, at his walk's speeds toward his target, standing, facing it.
fn walk(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    a.pause(false);
    e.velocity.x = n.walk_speed;
    e.velocity.depth = n.walk_speed;
    aim(a);
    a.animate(.walk);
    faceTarget(a);
}

/// Whether he was drawn in the screen's middle at the last tick.
fn onScreen(a: Actor) bool {
    return a.mind.drawn >= 0 and a.mind.drawn < 320;
}

/// Whether he was drawn left of `edge` across at the last tick, or from `edge` on (`from`), as
/// the original compares the place drawn: an unsigned word from 128 pixels left of the screen.
fn drawnBeyond(a: Actor, edge: i16, from: bool) bool {
    const at: u16 = @bitCast(@as(i16, @truncate(@as(i32, a.mind.drawn) + 128)));
    const line: u16 = @bitCast(edge + 128);
    return if (from) at >= line else at < line;
}

/// Whether his target was drawn above the line `screen_top` at the last tick.
fn targetHigh(a: Actor) bool {
    return seen(a).line < a.numbers().screen_top;
}

/// A shake across: his step, then the other way.
fn shakeStep(a: Actor) void {
    const m = a.mind;
    a.entity.position.x = a.entity.position.x.add(.pixels(m.shake));
    m.shake = -m.shake;
}

/// Knocked away from his target: up and away along the way it faces, slowing.
fn knockAway(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    a.mind.accel = n.knock_away_slowing;
    e.velocity.height = n.knock_away_up;
    e.velocity.x = n.knock_away_x;
    if (seen(a).left) {
        e.velocity.x = e.velocity.x.neg();
        a.mind.accel = a.mind.accel.neg();
    }
}

/// His target's power (the damage of its blow under way).
fn targetPower(a: Actor) i16 {
    const t = target(a) orelse return 0;
    return a.tick.power(t);
}

/// Damage `damage` from `by`; his health gone, he falls for good.
fn hurt(a: Actor, by: ?Handle, damage: i16) void {
    a.tick.takeDamage(a.handle, by, damage);
    if (a.entity.health > 0) return;
    setState(a, .defeated);
}

/// Among the things that hit the others (knocked away, thrown): his body strikes the enemies it
/// meets, for the player who sent him.
fn joinHitters(a: Actor, by: ?Handle) void {
    const h = by orelse return;
    a.entity.missile = .{ .by = h, .damage = a.numbers().missile_damage };
}

// What meets him ----------------------------------------------------------------------------------

/// His look at what met him at this tick (a player that met him becomes his target): a player's
/// blow shakes him, or knocks him away when it knocks down, with its damage; a grab sends him by
/// the player's request; a thing thrown knocks him away; else his frame's blow on a player.
fn hitCheck(a: Actor) void {
    const m = a.mind;
    switch (m.hit) {
        .none => blowOnPlayers(a),
        .blow => |b| {
            if (a.tick.isPlayer(b.by)) m.target = b.by;
            a.sound(.hurt);
            setState(a, .struck);
            if (!b.knocks_down) return hurt(a, b.by, b.damage);
            setState(a, .knocked_away);
            knockAway(a);
            hurt(a, b.by, targetPower(a));
        },
        .grab => |g| {
            if (a.tick.isPlayer(g)) m.target = g;
            const holder = a.other(g) orelse return;
            const s = a.tables().grab_states[boss_r3.request(holder)];
            if (s < 0) return;
            setState(a, @fromBackingInt(@intCast(s)));
        },
        .missile => |by| {
            a.sound(.hurt);
            setState(a, .knocked_away);
            knockAway(a);
            hurt(a, by, 1 + targetPower(a));
        },
    }
}

/// His frame's blow meets a player's body (player 1's first; not one struck at this tick): the
/// player is knocked down by his power.
fn blowOnPlayers(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    const attack = e.boxes.attack orelse return;
    const k = a.kind.definition;
    for (a.tick.world.players) |p| {
        const ph = p.entity orelse continue;
        const pe = a.other(ph) orelse continue;
        if (pe.mind != .player or !a.tick.catchable(ph)) continue;
        const body = pe.boxes.body orelse continue;
        if (!systems.meet(e, &k.boxes[attack], pe, &a.tick.kindOf(pe).definition.boxes[body])) continue;
        m.target = ph;
        _ = a.tick.struck(ph, .{ .attacker = a.handle, .damage = m.power, .reaction = .knock_down, .push = .zero });
        return;
    }
}

// Coming in, getting up ------------------------------------------------------------------------------

/// His first tick (the status bar shows him, his health and power by the level), and each time he
/// gets up: on his feet a while (his knocked animation's third frame), facing his target; then
/// standing, he sizes it up.
fn appear(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    switch (m.step) {
        0, 1 => {
            if (m.step == 0) firstTick(a);
            a.pause(true);
            m.ticks = n.get_up_ticks;
            m.step = 2;
            a.animate(.knocked);
            a.setFrame(n.get_up_frame);
            faceTarget(a);
        },
        else => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            walk(a);
            a.pause(true);
            m.ticks = n.size_up_ticks;
            m.state = .size_up;
        },
    }
}

fn firstTick(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    const w = a.tick.world;
    const t = a.tables();
    e.flags.hidden = false;
    e.flags.stays = true;
    w.boss_bar = bar_entry;
    w.bosses[0] = a.handle;
    const level: usize = if (a.tick.plan) |p| p.level else 1;
    e.health = t.strength[2 * level];
    m.power = t.strength[2 * level + 1];
    e.power = m.power;
}

// Sizing up, approaching, closing in, backing off ----------------------------------------------------

fn sizeUp(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (!onScreen(a)) {
        const r = a.draw(.mr_x_size_up) & 1;
        return setState(a, if (r == 0) .close else .approach);
    }
    if (reach(a, n.reach_level, n.reach_near).x < n.close_within) return setState(a, .close);
    m.ticks -%= 1;
    if (m.ticks == 0) return setState(a, .burst);
    looks(a, .face);
}

fn approach(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (m.step == 0) {
        a.pause(false);
        chooseTarget(a);
        walk(a);
        aim(a);
        e.velocity.depth = n.approach_depth;
        if (!targetHigh(a)) e.velocity.depth = e.velocity.depth.neg();
        m.step = 1;
        return;
    }
    move(a);
    if (!n.depth_least.lessThan(e.position.depth)) {
        e.position.depth = n.depth_least;
        e.velocity.depth = .zero;
    } else if (!e.position.depth.lessThan(n.depth_most)) {
        e.position.depth = n.depth_most;
        e.velocity.depth = .zero;
    }
    const edge = if (e.velocity.x.raw < 0) drawnBeyond(a, n.edge_left, false) else drawnBeyond(a, n.edge_right, true);
    if (edge) {
        faceTarget(a);
        e.velocity.depth = n.approach_depth;
        aim(a);
        m.ticks = n.size_up_ticks;
        a.pause(true);
        m.state = .size_up;
        return;
    }
    const r = reach(a, n.reach_level, n.reach_near);
    if (!r.far_depth and !r.far_x) return setState(a, .dash);
    looks(a, .none);
}

fn close(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (m.step == 0) {
        chooseTarget(a);
        walk(a);
        m.step = 1;
        return;
    }
    const r = reach(a, n.reach_level, n.close_near);
    if (!r.far_depth and !r.far_x) return setState(a, .dash);
    if (r.far_depth) e.position.depth = e.position.depth.add(e.velocity.depth);
    if (r.far_x) e.position.x = e.position.x.add(e.velocity.x);
    if (!n.burst_depth.lessThan(e.position.depth)) e.position.depth = n.burst_depth;
    faceTarget(a);
    aim(a);
    looks(a, .none);
}

fn backOff(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    // Its first tick goes on to the next step's.
    if (m.step == 0) {
        walk(a);
        e.velocity.x = e.velocity.x.neg();
        e.velocity.depth = .zero;
        m.ticks = n.back_off_ticks;
        m.step = 1;
    }
    if (!drawnBeyond(a, n.edge_left, false) and !drawnBeyond(a, n.edge_right, true)) {
        m.ticks -%= 1;
        if (m.ticks != 0) return looks(a, .move);
    }
    chooseTarget(a);
    m.ticks = n.size_up_ticks;
    m.state = .walk;
}

// The dash, the burst -------------------------------------------------------------------------------

fn dash(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    switch (m.step) {
        0 => {
            a.pause(true);
            faceTarget(a);
            a.animate(.dash);
            e.velocity.depth = .zero;
            e.velocity.x = n.dash_speed.neg();
            m.accel = n.dash_slowing;
            if (!e.facingLeft()) {
                e.velocity.x = e.velocity.x.neg();
                m.accel = m.accel.neg();
            }
            m.ticks = n.dash_ticks;
            m.step = 1;
        },
        1 => {
            m.ticks -%= 1;
            if (m.ticks == 0) {
                m.ticks = n.dash_still;
                m.step = 2;
                return;
            }
            e.velocity.x = e.velocity.x.add(m.accel);
            looks(a, .move);
        },
        else => {
            m.ticks -%= 1;
            if (m.ticks != 0) return looks(a, .none);
            setState(a, .back_off);
            if (!onScreen(a)) return looks(a, .none);
            if (a.draw(.mr_x_dash) & n.dash_fire != 0) return;
            m.state = .burst;
            looks(a, .none);
        },
    }
}

fn burst(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    switch (m.step) {
        0 => {
            chooseTarget(a);
            walk(a);
            e.velocity.depth = n.burst_up;
            e.velocity.x = .zero;
            m.step = 1;
        },
        1 => {
            if (n.burst_depth.lessThan(e.position.depth)) {
                move(a);
                return looks(a, .none);
            }
            e.position.depth = n.burst_depth;
            a.pause(false);
            a.animate(.raise);
            m.ticks = n.raise_ticks;
            m.step = 2;
            m.seen = 0xFF;
        },
        2 => {
            m.ticks -%= 1;
            if (m.ticks != 0) {
                if (m.ticks <= n.raise_still) a.pause(true);
                return looks(a, .none);
            }
            // His gun aimed his target's way, its frames his.
            a.pause(false);
            faceTarget(a);
            a.animate(.aim);
            a.pause(true);
            m.ticks = n.burst_frames;
            m.period = n.burst_period;
            m.step = 3;
        },
        else => {
            m.period -%= 1;
            if (m.period == 0) {
                m.period = n.burst_period;
                m.ticks -%= 1;
                if (m.ticks == 0) {
                    chooseTarget(a);
                    walk(a);
                    return setState(a, .approach);
                }
                a.setFrame(a.frame() + 1);
            }
            fire(a);
            looks(a, .none);
        },
    }
}

/// At each new even frame of his aim, a shot by the frame's index his way, and a cartridge of
/// the index the other way flying the other way, in the enemies' first free places.
fn fire(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    const f = a.frame();
    if (f == m.seen) return;
    m.seen = f;
    if (f & 1 != 0) return;
    const index = f >> 1;
    const left = e.facingLeft();
    const sh = makeAt(a, shot_kind, e.position) orelse return;
    if (a.tick.actor(shot_mod, sh)) |s| {
        s.mind.index = index;
        s.mind.left = left;
        s.mind.by = a.handle;
    }
    const ch = makeAt(a, cartridge_kind, e.position) orelse return;
    if (a.tick.actor(cartridge_mod, ch)) |c| {
        c.mind.index = 7 -% index;
        c.mind.left = !left;
    }
}

/// A thing of kind `name` at `at`, in the enemies' first free place.
fn makeAt(a: Actor, name: []const u8, at: fixed.Vec3) ?Handle {
    const k = a.tick.kinds.find(name) orelse return null;
    const places = world_mod.World.enemy_places;
    return a.tick.world.spawnWithin(a.tick.kinds, k, places.from, places.to, at, .right) catch null;
}

// Struck, knocked away --------------------------------------------------------------------------------

fn struck_(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (m.step == 0) {
        a.pause(true);
        a.animate(.struck);
        m.ticks = n.struck_ticks;
        m.step = 1;
        m.shake = n.shake;
        return;
    }
    m.ticks -%= 1;
    if (m.ticks == 0) return setState(a, .back_off);
    shakeStep(a);
}

fn knockedAway(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    switch (m.step) {
        0 => {
            joinHitters(a, m.target);
            a.pause(true);
            e.facing = if (e.velocity.x.raw < 0) .right else .left;
            a.animate(.knocked);
            m.gravity = n.knocked_gravity;
            e.velocity.depth = .zero;
            m.step = 1;
        },
        1 => rise(a),
        2 => {
            fall(a);
            if (m.step == 2) return;
            m.ticks = n.knocked_lie_ticks;
            m.step = 3;
            e.velocity.height = .zero;
        },
        else => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            e.missile = null;
            setState(a, .appear);
            m.step = 1;
        },
    }
}

/// Rising: his speeds change (across by his slowing, in height by his gravity) and he moves;
/// once falling, still in height, his next frame, a lighter gravity.
fn rise(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (e.velocity.height.raw > 0) {
        e.velocity.height = .zero;
        m.gravity = n.falling_gravity;
        a.setFrame(a.frame() + 1);
        m.step = 2;
        return;
    }
    e.velocity.x = e.velocity.x.add(m.accel);
    e.velocity.height = e.velocity.height.add(m.gravity);
    move(a);
}

/// Falling to his floor: there, the thud and a bounce at an eighth of the speed while it is fast,
/// else he lies (`lie_ticks`, the next step).
fn fall(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (e.position.height.whole() < n.floor) {
        e.velocity.x = e.velocity.x.add(m.accel);
        e.velocity.height = e.velocity.height.add(m.gravity);
        return move(a);
    }
    e.position.height = .pixels(n.floor);
    a.sound(.thud);
    if (n.bounce_above.lessThan(e.velocity.height)) {
        e.velocity.height = e.velocity.height.neg().shr(n.bounce_shift);
        return move(a);
    }
    e.velocity.height = .zero;
    m.ticks = n.lie_ticks;
    m.step = 3;
}

// Held by a player -------------------------------------------------------------------------------------

/// The one holding him.
fn holderOf(a: Actor) ?*Entity {
    return a.other(a.mind.holder orelse return null);
}

/// At his holder's place.
fn toHolder(a: Actor) void {
    const h = holderOf(a) orelse return;
    a.entity.position = h.position;
}

/// The hold ends: neither holds the other.
fn breakFree(a: Actor) void {
    a.letGo();
}

/// Grabbed in front of a player: a new target, standing still in front of his holder on the
/// floor, a while (not while his target throws back); then what met him, and his target's
/// requests (`grabbedMet`); shaken by a knee; the last knee knocks him away a moment later.
fn grabbed(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    switch (m.step) {
        0 => {
            chooseTarget(a);
            walk(a);
            aim(a);
            a.pause(true);
            m.ticks = n.grabbed_ticks;
            m.step = 1;
            toHolder(a);
            var ahead: i32 = n.grabbed_ahead;
            e.facing = .left;
            if (holderOf(a)) |h| if (h.facingLeft()) {
                e.facing = .right;
                ahead = -ahead;
            };
            e.position.x = e.position.x.add(.pixels(ahead));
            if (a.tick.floorUnder(e.position)) |f| e.position.height = .pixels(f.whole());
        },
        1 => {
            const t = target(a);
            const throws_back = if (t) |x| boss_r3.request(x) == 9 else false;
            if (!throws_back) {
                m.ticks -%= 1;
                if (m.ticks == 0) {
                    breakFree(a);
                    return setState(a, .back_off);
                }
            }
            looks(a, .none);
        },
        2 => {
            a.sound(.hurt);
            a.animate(.struck);
            m.ticks = n.struck_ticks;
            m.step = 3;
            m.shake = n.shake;
        },
        3 => {
            m.ticks -%= 1;
            if (m.ticks == 0) {
                m.step = 0;
                return;
            }
            shakeStep(a);
        },
        else => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            breakFree(a);
            setState(a, .knocked_away);
            knockAway(a);
            hurt(a, m.target, targetPower(a));
        },
    }
}

/// Grabbed: another's blow or a thing thrown knocks him away from the hold; else his target's
/// request: let go, he backs off; a knee hurts him (shaken); the last knee knocks him away soon;
/// a throw throws him; a vault puts him held from behind; a throw back gives the hold more time.
fn grabbedMet(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    switch (m.hit) {
        .blow => |b| return grabbedStruck(a, b.by),
        .missile => |by| return grabbedStruck(a, by),
        .grab, .none => {},
    }
    const t = target(a) orelse return;
    switch (boss_r3.request(t)) {
        0 => {
            breakFree(a);
            setState(a, .back_off);
        },
        3 => {
            hurt(a, m.target, targetPower(a));
            if (m.state == .defeated) return breakFree(a);
            m.step = 2;
        },
        4 => {
            m.ticks = n.grabbed_wait;
            m.step = 4;
        },
        5, 7 => setState(a, .thrown),
        6 => setState(a, .held_behind),
        9 => m.ticks = n.grabbed_hold,
        else => {},
    }
}

/// Struck in a hold by `by`: his health a point less, out of the hold, knocked away.
fn grabbedStruck(a: Actor, by: Handle) void {
    a.sound(.hurt);
    a.tick.takeDamage(a.handle, by, 1);
    breakFree(a);
    setState(a, .knocked_away);
    knockAway(a);
}

/// His place by the holder's character, row `row` at his target's frame: across (the other way
/// for a negative `way`) and in height.
fn throwPlace(a: Actor, row: usize, way: i16) void {
    const t = target(a) orelse return;
    boss_r3.placeThrown(a.entity, t, a.tick.kindOf(t).definition.name, a.tables(), row, way);
}

/// Held from behind: facing as his target does, at his holder's place by the hold's places, a
/// while; let go, or his time out, he backs off; his target's slam slams him down.
fn heldBehind(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (m.step == 0) {
        a.pause(true);
        const left = if (target(a)) |t| t.facingLeft() else false;
        m.dir = if (left) 1 else -1;
        e.facing = if (left) .left else .right;
        a.animate(.held_behind);
        toHolder(a);
        throwPlace(a, 0, m.dir);
        e.velocity.depth = .zero;
        m.ticks = n.held_ticks;
        m.step = 1;
        return;
    }
    const free = m.let_go;
    m.let_go = false;
    if (!free) {
        m.ticks -%= 1;
        if (m.ticks != 0) {
            const r = if (target(a)) |t| boss_r3.request(t) else 0;
            if (r == 6) return setState(a, .slammed);
            if (r == 2) return;
        }
    }
    setState(a, .back_off);
}

/// Slammed down by his target: following its frames, and at its slam's the shake and the thud; a
/// while later he is knocked away with the slam's damage.
fn slammed(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const hf: u8 = if (target(a)) |t| t.animation.frame else 0;
    switch (m.step) {
        0, 1 => {
            if (m.step == 0) {
                if (hf == 0) return;
                m.seen = hf;
                a.setFrame(a.frame() + 1);
                m.step = 1;
                throwPlace(a, 1, m.dir);
            }
            if (hf == m.seen) return;
            m.seen = hf;
            if (hf == n.slammed_frame) {
                a.tick.shake();
                a.sound(.thud);
                m.ticks = n.slammed_ticks;
                m.step = 2;
            } else {
                a.setFrame(@min(a.frame() + 1, 2));
            }
            throwPlace(a, 1, m.dir);
        },
        else => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            e.velocity.height = n.slammed_up;
            m.gravity = n.slammed_gravity;
            e.velocity.x = n.slammed_x;
            m.accel = n.slammed_slowing;
            if (!e.facingLeft()) {
                e.velocity.x = e.velocity.x.neg();
                m.accel = m.accel.neg();
            }
            m.let_go = false;
            setState(a, .knocked_away);
            hurt(a, m.target, n.slammed_damage);
        },
    }
}

/// Thrown by his target: along its facing (Blaze's the other way), up and across; at the top
/// placed on and falling; on the floor a shake and a bounce; then the throw's damage (his health
/// gone, he falls for good) and he slides a little before getting up. Thrown, he strikes the
/// enemies he meets.
fn thrown(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    switch (m.step) {
        0 => {
            a.pause(true);
            var way: i16 = 1;
            if (target(a)) |t| {
                if (t.facingLeft()) way = -1;
                if (std.mem.eql(u8, a.tick.kindOf(t).definition.name, "blaze")) way = -way;
            }
            m.dir = way;
            e.facing = if (way < 0) .left else .right;
            a.animate(.thrown);
            a.setFrame(1);
            m.step = 1;
            joinHitters(a, m.target);
            toHolder(a);
            throwPlace(a, 2, m.dir);
            e.velocity.depth = .zero;
            e.velocity.height = n.thrown_up;
            m.gravity = n.thrown_gravity;
            e.velocity.x = n.thrown_x;
            m.accel = n.thrown_slowing;
            if (m.dir < 0) {
                e.velocity.x = e.velocity.x.neg();
                m.accel = m.accel.neg();
            }
        },
        1 => {
            if (e.velocity.height.whole() < 0) {
                e.velocity.height = e.velocity.height.add(m.gravity);
                e.velocity.x = e.velocity.x.add(m.accel);
                return move(a);
            }
            var over: i32 = n.thrown_over;
            e.velocity.x = n.thrown_x;
            if (m.dir < 0) {
                over = -over;
                e.velocity.x = e.velocity.x.neg();
            }
            e.position.x = e.position.x.add(.pixels(over));
            e.velocity.height = n.thrown_down;
            m.gravity = n.thrown_gravity;
            a.setFrame(a.frame() + 1);
            m.step = 2;
        },
        2 => {
            if (e.position.height.whole() < n.floor) {
                e.velocity.height = e.velocity.height.add(m.gravity);
                return move(a);
            }
            e.position.height = .pixels(n.floor);
            a.tick.shake();
            e.velocity.height = n.thrown_bounce;
            m.ticks = 0;
            m.step = 3;
            move(a);
        },
        3 => {
            fall(a);
            if (m.ticks != n.lie_ticks) return;
            e.missile = null;
            hurt(a, m.target, n.thrown_damage);
            if (m.state == .defeated) return;
            e.velocity.x = e.velocity.x.shr(1);
            m.ticks = n.thrown_slide;
            m.step = 4;
        },
        else => {
            m.ticks -%= 1;
            if (m.ticks != 0) return move(a);
            m.let_go = false;
            setState(a, .appear);
            m.step = 1;
        },
    }
}

// Defeated ---------------------------------------------------------------------------------------------

/// His fall for good: the round's timer stops and the boss is beaten (the enemies knocked down);
/// thrown up and away from his target he spills cartridges, falls, bounces, lies; he rises
/// groaning, drops shaking, gives his points; then the round is won.
fn defeated(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    switch (m.step) {
        0 => {
            breakFree(a);
            e.missile = null;
            a.tick.world.timer.stopped = true;
            a.tick.bossBeaten();
            a.sound(.hurt);
            a.pause(true);
            e.velocity.depth = .zero;
            m.accel = .zero;
            m.gravity = n.defeated_gravity;
            e.velocity.x = n.defeated_x;
            e.velocity.height = n.defeated_up;
            a.animate(.struck);
            faceTarget(a);
            aim(a);
            e.velocity.x = e.velocity.x.neg();
            m.step = 1;
        },
        1 => {
            if (drawnBeyond(a, n.edge_left, false) or drawnBeyond(a, n.edge_right, true)) e.velocity.x = .zero;
            if (e.velocity.height.raw > 0) {
                e.velocity.x = .zero;
                m.gravity = n.defeated_falling;
                a.animate(.knocked);
                a.setFrame(1);
                faceTarget(a);
                m.step = 2;
                return;
            }
            e.velocity.height = e.velocity.height.add(m.gravity);
            spill(a);
            move(a);
        },
        2 => {
            if (e.position.height.whole() >= n.floor) {
                e.position.height = .pixels(n.floor);
                a.sound(.thud);
                e.velocity.height = n.defeated_bounce;
                m.gravity = n.defeated_bounce_gravity;
                m.step = 3;
                return move(a);
            }
            e.velocity.height = e.velocity.height.add(m.gravity);
            if (n.defeated_most.lessThan(e.velocity.height)) e.velocity.height = n.defeated_most;
            spill(a);
            move(a);
        },
        3 => {
            const floor = a.tick.floorUnder(e.position);
            if (floor == null or e.position.height.lessThan(floor.?)) {
                e.velocity.height = e.velocity.height.add(m.gravity);
                return move(a);
            }
            e.position.height = .pixels(floor.?.whole());
            a.sound(.thud);
            if (!e.velocity.height.lessThan(n.defeated_rest)) {
                e.velocity.height = e.velocity.height.shr(1).neg();
                return move(a);
            }
            m.ticks = n.defeated_lie;
            m.step = 4;
        },
        4 => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            a.setFrame(n.defeated_frame);
            m.step = 5;
            m.ticks = n.defeated_lie;
        },
        5 => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            m.dir = n.defeated_sway;
            a.animate(.struck);
            faceTarget(a);
            m.ticks = n.defeated_rise;
            m.step = 6;
            a.sound(.groan);
        },
        6 => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            a.animate(.knocked);
            faceTarget(a);
            a.setFrame(1);
            m.ticks = n.defeated_down;
            m.step = 7;
            a.tick.shake();
        },
        7 => {
            m.ticks -%= 1;
            if (m.ticks != 0) {
                e.position.height = e.position.height.add(.pixels(m.dir));
                m.dir = -m.dir;
                return;
            }
            if (a.tick.floorUnder(e.position)) |f| e.position.height = .pixels(f.whole());
            m.ticks = n.defeated_down;
            m.step = 8;
            points(a);
        },
        8 => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            m.step = 9;
            a.tick.roundWon();
        },
        else => {},
    }
}

/// In his flight and fall, every few ticks a cartridge spilled at his place: of an index drawn,
/// a height drawn up, behind or ahead of him across by a draw (his way the other way).
fn spill(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    m.ticks -%= 1;
    if (m.ticks % n.spill_every != n.spill_every - 1) return;
    const ch = makeAt(a, cartridge_kind, e.position) orelse return;
    const c = a.tick.actor(cartridge_mod, ch) orelse return;
    c.mind.spilled = true;
    c.mind.index = @intCast(a.draw(.mr_x_spill) & 7);
    c.entity.position.height = c.entity.position.height.sub(.pixels(a.draw(.mr_x_spill) & n.spill_height));
    var dx: i32 = @as(i32, a.draw(.mr_x_spill) & n.spill_spread) - n.spill_ahead;
    if (e.facingLeft()) {
        c.mind.left = true;
        dx = -dx;
    }
    c.entity.position.x = c.entity.position.x.add(.pixels(dx));
}

/// His points: to player 2 when it is his target, else to player 1.
fn points(a: Actor) void {
    const n = a.numbers();
    const w = a.tick.world;
    const second = if (a.mind.target) |t| if (w.players[1].entity) |p2| p2.eql(t) else false else false;
    const p = &w.players[if (second) 1 else 0];
    p.score = @min(p.score +| n.points, w.score_most);
}
