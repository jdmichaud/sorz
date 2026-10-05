//! Antonio, round 1's boss, with his boomerang (boomerang.zig). He comes in from the screen's
//! side and sets on the nearer player:
//! - `walk`, his ways of walking, one at a time (`Walk`): off the screen he walks in, across and
//!   in depth; on it, a target that comes near makes him back away a while, keeping a little
//!   above it in depth; one far off makes him taunt, then stroll about, stand, and stroll on,
//!   swaying in depth; then he goes to his target's depth, throws his boomerang, and waits for it,
//!   walking up to catch it; near, but not too near, and level with his target, he charges it;
//! - `swing` (the traces' `throw`): near enough, level, he swings his boomerang in hand, a blow
//!   that knocks down;
//! - struck: a blow's damage is taken at his next tick; he is knocked back, shaking a moment, or
//!   down (a blow that knocks down, his last health, or struck in the air): flying back, landing
//!   and bouncing (`knocked_back`), then lying a moment (`down`);
//! - `held` in front or from behind: a knee costs him health and knocks him back, still held; the
//!   last knee knocks him down off the hold; thrown, he flies as a thing thrown (`tossed`,
//!   `vaulted`, `flung`) and lands hard;
//! - a special attack holds him still (`special_still`), then costs him health and knocks him
//!   down; a player's new life knocks him down, sparing his health;
//! - beaten (no health left, down), he blinks, the player who struck him last scores his points,
//!   and a moment later the round is won and he goes, his boomerangs with him.
//! The status bar shows his health (`World.boss_bar`, `World.bosses`), from his first tick.
//! His numbers, animations and sounds are his definition's (`entities/antonio.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const behaviours = @import("../behaviours.zig");
const script = @import("../script.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Entity = entity.Entity;
const Actor = tick.Actor(@This());

pub const State = enum {
    appear,
    walk,
    swing,
    knocked_back,
    held,
    down,
    tossed,
    vaulted,
    flung,
    special_still,
};

/// The traces' names of his states that are not theirs.
pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "throw", .state = .swing },
    .{ .name = "thrown6", .state = .tossed },
    .{ .name = "thrown7", .state = .vaulted },
    .{ .name = "thrown8", .state = .flung },
};

/// His ways of walking.
pub const Walk = enum(u4) {
    /// Near his target, he backs away a while; far off, he taunts, or goes to its depth.
    decide,
    taunt,
    /// He strolls across, swaying in depth, then stands, then strolls on.
    stroll,
    stand,
    approach,
    /// He goes to his target's depth, then throws his boomerang.
    level,
    throw,
    /// He waits for his boomerang, walking up to it, and catches it.
    wait,
    charge,
    walk_in,
};

/// What a hold's holder does to him, by the holder's state.
const Hold = packed struct(u8) {
    /// A grab took him (he is held from the next tick); placed in front of the holder, or with
    /// his back to it; thrown.
    grabbed: bool = false,
    front: bool = false,
    behind: bool = false,
    thrown: bool = false,
    _: u4 = 0,

    fn placed(h: Hold) bool {
        return h.front or h.behind or h.thrown;
    }
};

pub const Mind = struct {
    state: State = .appear,
    walk: Walk = .decide,
    /// The walk's timer, which goes on from one way of walking to the next; the other states'
    /// timer; the bounces left of a fall.
    timer: u8 = 0,
    count: u8 = 0,
    bounces: u8 = 0,
    /// His sway in depth (never reset), the walk in's ticks left once on the screen.
    sway: u8 = 0,
    walk_in: u8 = 0,
    /// The special attack: the ticks it holds him still, and until he is put back on the ground.
    special_left: u16 = 0,
    grounded_in: u8 = 0,
    /// The damage of a blow met, taken at his next tick; whether it knocks down; who dealt it
    /// (or called the special attack).
    damage: u8 = 0,
    knocks_down: bool = false,
    attacker: ?Handle = null,
    /// The hold he is in, his holder (who took him last), and whether it let him go.
    hold: Hold = .{},
    holder: ?Handle = null,
    let_go: bool = false,
    /// The target of this tick; whether it may be set on.
    target: ?Handle = null,
    unattackable: bool = false,
    /// From him to the one he measured last: on his left, above him (a smaller depth), and how
    /// far across and in depth (whole pixels).
    left_of: bool = false,
    above: bool = false,
    dx: u16 = 0,
    dd: u16 = 0,
    /// The place of his boomerang in the world (the original keeps the place, not the thing).
    boomerang: ?u8 = null,
    /// Where he was drawn across the screen at the last tick.
    drawn: i16 = 0,
    /// The ground under him, his power, his place among twins (0 alone, 1 the first, 2 the
    /// second) and his twin's place.
    ground: Fixed = .zero,
    power: u8 = 0,
    twin: u2 = 0,
    twin_at: ?u8 = null,
    twin_beaten: bool = false,
    /// This tick ended before his blows were met; a special attack came, he took it; a player's
    /// new life knocks him down.
    ended: bool = false,
    special_new: bool = false,
    special_taken: bool = false,
    blast: bool = false,
};

pub const Animation = enum { stand, swing, knocked, held, held_behind, flight, bounce, down, lifted, idle, walk, taunt, throw, wait };
pub const Move = enum { swing };
pub const Sound = enum { swing, hurt, cry, thud };

pub const Tables = struct {
    /// Carried over a thrower's head, step by step: back from the thrower, then down.
    carried: [10]i8,
};

pub const Numbers = struct {
    power: u8,
    hardest_health: u8,
    outside_power: u8,
    /// Where he was drawn across the screen: on it, its middle; walking in, his speed (across and
    /// in depth), the depth of his target from which he walks in upward, and the ticks he walks
    /// on once on the screen (the second of twins').
    on_screen_from: i16,
    on_screen_to: i16,
    screen_middle: i16,
    walk_in_speed: Fixed,
    walk_in_low: i16,
    walk_in_ticks: u8,
    walk_in_ticks_second: u8,
    /// A blow lands on him drawn within these; a grab within this height.
    struck_from: i16,
    struck_to: i16,
    grab_height: i16,
    /// His target this near is near; the charge's span and level, its speed and where it stops.
    near: u16,
    charge_from: u16,
    charge_level: u16,
    charge_speed: Fixed,
    charge_stop_far: u16,
    charge_stop_near: u16,
    charge_stop_level: u16,
    /// The swing's reach: at a target coming at him, going away, still on his right, still on
    /// his left; its level, his target above him or not; the frame it starts at (but from the
    /// walk's frame `swing_from_start`, its first), its last.
    swing_reach_coming: u16,
    swing_reach_going: u16,
    swing_reach_still: u16,
    swing_reach_still_left: u16,
    swing_level_above: u16,
    swing_level: u16,
    swing_frame: u8,
    swing_from_start: u8,
    swing_ends: u8,
    /// Walking: backing away, taunting, strolling, standing, aligning, throwing, waiting.
    back_away_ticks: u8,
    back_away_speed: Fixed,
    taunt_from: u16,
    stroll_ticks: u8,
    stroll_toward_from: u16,
    stroll_speed: Fixed,
    stand_near: u16,
    stand_far_level: u16,
    stand_far_speed: Fixed,
    align_speed: Fixed,
    align_level: u16,
    depth_most: i16,
    throw_ticks: u8,
    charge_back_from: u16,
    charge_back_level: u16,
    catch_hand: i16,
    catch_within: u16,
    catch_steer: Fixed,
    zigzag_turn: u8,
    zigzag_back: u8,
    sway_speed: Fixed,
    /// Keeping a little above his target in depth, and going to its depth.
    keep_far: u16,
    keep_near: u16,
    keep_step_2: u16,
    keep_step_1: u16,
    keep_at: u16,
    steer_fast: Fixed,
    steer: Fixed,
    steer_slow: Fixed,
    level_far: u16,
    level_mid: u16,
    level_near: u16,
    /// Far out of the screen he is brought back, and slowed.
    edge_from: i16,
    edge_to: i16,
    push_from: i16,
    push_to: i16,
    /// Struck: knocked back a while, or down, flying and bouncing; the shake; lying; beaten.
    knock_back_ticks: u8,
    knock_down_ticks: u8,
    knocked_x: Fixed,
    knocked_up: Fixed,
    knocked_bounces: u8,
    knocked_gravity: Fixed,
    bounce_up: Fixed,
    shake: i16,
    down_ticks: u8,
    dead_ticks: u8,
    points_at: u8,
    points: u32,
    /// Held: his place from his holder; the knees' damage.
    hold_front: i16,
    hold_behind: i16,
    knee_damage: u8,
    last_knee_damage: u8,
    /// A thrown body's or a weapon's blow; what he does to the others thrown.
    missile_damage: u8,
    thrown_damage: u8,
    /// Thrown: tossed over the shoulder, vaulted over, flung behind.
    toss_place: i16,
    toss_ticks: u8,
    toss_lift_at: u8,
    toss_up: Fixed,
    toss_lift: i16,
    toss_x: Fixed,
    toss_ahead: i16,
    toss_bounce: Fixed,
    toss_bounce_2: Fixed,
    toss_damage: u8,
    vault_place: i16,
    vault_ticks: u8,
    vault_turn_at: u8,
    vault_over_at: u8,
    vault_down_at: u8,
    vault_damage: u8,
    vault_fly_at: u8,
    vault_fly: Fixed,
    vault_slide: Fixed,
    fling_place: i16,
    fling_ticks: u8,
    fling_lift_at: u8,
    fling_at: u8,
    fling_up: Fixed,
    fling_x: Fixed,
    fling_turn_at: u8,
    fling_bounce: Fixed,
    fling_bounce_2: Fixed,
    fling_damage: u8,
    thrown_bounces: u8,
    thrown_gravity: Fixed,
    /// The special attack: until he is grounded, how long it holds him (the second player's),
    /// its damage; then knocked down as a player's new life does (dying, faster).
    special_grounded: u8,
    special_ticks: u16,
    special_ticks_second: u16,
    special_damage: u8,
    blast_x: Fixed,
    blast_up: Fixed,
    dying_x: Fixed,
    blast_ticks: u8,
    blast_bounces: u8,
};

/// The boomerang's kind.
pub const boomerang_kind = "boomerang";

// The tick -----------------------------------------------------------------------------------

/// His tick until his blows are met: a special attack or a player's new life may end it; then
/// his state's first part (his target, the damage of a blow met at the last tick, what his
/// holder does to him).
pub fn begin(a: Actor) void {
    const m = a.mind;
    m.ended = false;
    a.entity.flags.still = true;
    a.pause(false);
    // With no player in play, he stands frozen.
    if (a.tick.fighting(0) == null and a.tick.fighting(1) == null) {
        if (m.state != .appear) {
            a.pause(true);
            m.ended = true;
        }
        return;
    }
    if (special(a)) return end(a);
    if (blast(a)) return end(a);
    switch (m.state) {
        .appear => {
            appear(a);
            end(a);
        },
        .walk => {
            m.let_go = false;
            const t = chooseTarget(a) orelse return end(a);
            m.target = t;
            m.unattackable = !a.tick.attackable(t);
            measure(a, a.other(t).?, true);
            if (takeDamage(a) or holdTaken(a)) end(a);
        },
        .swing => {
            m.let_go = false;
            if (takeDamage(a) or holdTaken(a)) end(a);
        },
        .held => {
            if (m.holder) |h| if (a.other(h)) |holder| measure(a, holder, false);
            if (takeDamage(a) or holdTaken(a)) end(a);
        },
        else => {},
    }
}

/// His tick after his blows were met.
pub fn think(a: Actor) void {
    const m = a.mind;
    if (!m.ended) switch (m.state) {
        .appear => {},
        .walk => walk(a),
        .swing => swing(a),
        .held => held(a),
        .knocked_back => knockedBackTick(a),
        .down => down(a),
        .tossed => tossed(a),
        .vaulted => vaulted(a),
        .flung => flung(a),
        .special_still => specialStill(a),
    };
    if (!a.entity.alive()) return;
    // Where he is drawn at the tick's end.
    if (!a.entity.flags.hidden) m.drawn = @intCast(a.entity.position.x.whole() - a.tick.world.camera.x.whole());
}

/// The rest of the tick is not his.
fn end(a: Actor) void {
    a.mind.ended = true;
}

// Coming in ----------------------------------------------------------------------------------

/// His first tick: the ground he stands on is his; his twin found; the status bar shows him; his
/// power and health by the level; he walks.
fn appear(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    m.ground = e.position.height;
    pairUp(a);
    if (inFight(a)) onBar(a);
    const s = strength(a);
    m.power = s.power;
    e.power = s.power;
    e.health = s.health;
    m.state = .walk;
    m.walk = .decide;
    e.facing = .right;
    a.animate(.stand);
}

/// Whether the boss's section has begun (without a round's script, as in the tests: yes).
fn inFight(a: Actor) bool {
    const p = a.tick.plan orelse return true;
    return script.bossFight(a.tick.world, p);
}

/// The status bar shows his health (from his boss's section only): one placed as the first of
/// twins (or alone) in its first bar, unless the bar shows twins already; one placed as the
/// second in its second, the bar showing twins. The bar keeps him until the next round's load.
fn onBar(a: Actor) void {
    const w = a.tick.world;
    const bar = a.entity.spawn.bar orelse return;
    if (!a.entity.spawn.traits.twin) {
        if (w.boss_bar == null or w.boss_bar.? != bar + 1) w.boss_bar = bar;
        w.bosses[0] = a.handle;
    } else {
        w.boss_bar = bar;
        w.bosses[1] = a.handle;
    }
}

/// His power and health by the level: the easiest halves his power, the harder ones double it,
/// the hardest adds to his health; out of his boss's section, his power is more.
fn strength(a: Actor) struct { power: u8, health: i16 } {
    const n = a.numbers();
    var power: u8 = n.power;
    var health: i16 = a.kind.definition.health;
    const level: u2 = if (a.tick.plan) |p| p.level else 1;
    switch (level) {
        0 => power >>= 1,
        1 => {},
        2 => power *%= 2,
        3 => {
            health += n.hardest_health;
            power *%= 2;
        },
    }
    if (!inFight(a)) power +%= n.outside_power;
    return .{ .power = power, .health = health };
}

/// The second of twins finds the first among the enemies: each knows the other.
fn pairUp(a: Actor) void {
    const m = a.mind;
    if (!a.entity.spawn.traits.twin) return;
    for (2..34) |i| {
        const o = &a.tick.world.entities[i];
        if (!o.alive() or i == a.handle.index or o.kind == null or o.kind.? != a.entity.kind.?) continue;
        m.twin = 2;
        m.twin_at = @intCast(i);
        const h = a.tick.world.handleAt(i).?;
        if (a.tick.actor(@This(), h)) |other| {
            other.mind.twin = 1;
            other.mind.twin_at = @intCast(a.handle.index);
        }
        return;
    }
}

/// His twin, while it is one.
fn twinOf(a: Actor) ?Actor {
    const at = a.mind.twin_at orelse return null;
    const h = a.tick.world.handleAt(at) orelse return null;
    return a.tick.actor(@This(), h);
}

/// The player he sets on: his holder when held; the only one in play; of two, the nearer across
/// (player 1 at a tie); twins each keep to their own player when it is within his near.
fn chooseTarget(a: Actor) ?Handle {
    const m = a.mind;
    if (m.hold.grabbed) if (m.holder) |h| if (a.other(h) != null) return h;
    const w = a.tick.world;
    const p1 = a.tick.fighting(0);
    const p2 = a.tick.fighting(1);
    if (p1 == null) return p2;
    if (p2 == null) return p1;
    const x = a.entity.position.x.whole();
    const to_first = @abs(w.get(p1.?).?.position.x.whole() - x);
    const to_second = @abs(x - w.get(p2.?).?.position.x.whole());
    const n = a.numbers();
    switch (m.twin) {
        1 => {
            if (to_second < n.near) return p1;
            if (to_first < n.near) return p2;
        },
        2 => {
            if (to_first < n.near) return p2;
            if (to_second < n.near) return p1;
        },
        else => {},
    }
    return if (to_second >= to_first) p1 else p2;
}

/// He measures himself against `o`: on which side across, how far, above or below and how far
/// in depth; facing it when `face` (dead level across: right).
fn measure(a: Actor, o: *const Entity, face: bool) void {
    const m = a.mind;
    const dx = o.position.x.whole() - a.entity.position.x.whole();
    m.left_of = dx < 0;
    m.dx = @intCast(@min(@abs(dx), std.math.maxInt(u16)));
    if (face) a.entity.facing = if (dx < 0) .left else .right;
    const dd = o.position.depth.whole() - a.entity.position.depth.whole();
    m.above = dd < 0;
    m.dd = @intCast(@min(@abs(dd), std.math.maxInt(u16)));
}

/// He faces his target (the side he measured it on), and shows animation `which` from its start.
fn faceAndShow(a: Actor, which: Animation) void {
    a.entity.facing = if (a.mind.left_of) .left else .right;
    a.animate(which);
}

/// He moves by his speeds: in depth no further than the ground's depths, down no further than his
/// ground.
fn move(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    e.position.x = e.position.x.add(e.velocity.x);
    var d = e.position.depth.add(e.velocity.depth);
    if (d.raw < 0) d = .zero;
    if (!d.lessThan(.pixels(n.depth_most))) d = .pixels(n.depth_most);
    e.position.depth = d;
    const h = e.position.height.add(e.velocity.height);
    e.position.height = if (@as(u32, @bitCast(h.raw)) > @as(u32, @bitCast(a.mind.ground.raw))) a.mind.ground else h;
}

fn stop(a: Actor) void {
    a.entity.velocity = .zero;
}

/// Whether he stands on his ground (whole pixels).
fn grounded(a: Actor) bool {
    return a.entity.position.height.whole() == a.mind.ground.whole();
}

// Walking ------------------------------------------------------------------------------------

fn walk(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const t = a.other(m.target orelse return) orelse return;
    if (@backingInt(m.walk) < @backingInt(Walk.throw)) supplyBoomerang(a);
    // Off the screen he walks in, across toward its middle and in depth toward his target's side.
    if (m.drawn < n.on_screen_from or m.drawn >= n.on_screen_to) {
        a.entity.velocity.x = if (m.drawn >= n.screen_middle) n.walk_in_speed.neg() else n.walk_in_speed;
        a.entity.velocity.depth = if (t.position.depth.whole() >= n.walk_in_low) n.walk_in_speed.neg() else n.walk_in_speed;
        m.walk_in = if (m.twin == 2) n.walk_in_ticks_second else n.walk_in_ticks;
        m.walk = .walk_in;
        if (!a.plays(.walk)) faceAndShow(a, .walk);
        return move(a);
    }
    var near = false;
    if (!m.unattackable) {
        near = m.dx < n.near;
        if (m.walk != .charge and m.dx < n.near and m.dx >= n.charge_from and m.dd < n.charge_level) return charge(a);
        if (swingReaches(a, t)) return startSwing(a);
    }
    switch (m.walk) {
        .decide => decide(a, near),
        .taunt => taunt(a, near),
        .stroll => stroll(a, near),
        .stand => stand(a, near),
        .approach => approach(a, near),
        .level => alignDepth(a, near),
        .throw => throwBoomerang(a),
        .wait => waitForBoomerang(a, t, near),
        .charge => charging(a),
        .walk_in => walkingIn(a),
    }
}

/// He charges his target, across, his way to it kept until he stops.
fn charge(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.walk = .charge;
    a.entity.velocity.x = if (m.left_of) n.charge_speed.neg() else n.charge_speed;
    if (!(a.plays(.stand) and a.entity.facing == .right)) faceAndShow(a, .stand);
    move(a);
}

/// Whether his swing reaches his target: across, by the way it goes (coming at him, going away,
/// still on his right or left); in depth, level with him.
fn swingReaches(a: Actor, t: *const Entity) bool {
    const n = a.numbers();
    const m = a.mind;
    var going = t.velocity.x.whole();
    const reach = if (going != 0) reach: {
        if (m.left_of) going = -going;
        break :reach if (going < 0) n.swing_reach_coming else n.swing_reach_going;
    } else if (!m.left_of) n.swing_reach_still else n.swing_reach_still_left;
    if (m.dx >= reach) return false;
    return m.dd < (if (m.above) n.swing_level_above else n.swing_level);
}

/// He swings at his target, from his swing's second frame (from its first when his walk showed
/// a given frame).
fn startSwing(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.walk = .decide;
    m.timer = 0;
    m.state = .swing;
    a.sound(.swing);
    const was = a.frame();
    a.entity.facing = if (m.left_of) .left else .right;
    a.startMove(.swing);
    if (was != n.swing_from_start) a.setFrame(n.swing_frame);
}

/// Near his target he backs away a while, keeping a little above it in depth; far off he
/// taunts, or goes to its depth.
fn decide(a: Actor, near: bool) void {
    const n = a.numbers();
    const m = a.mind;
    if (m.timer == 0) {
        if (!near) {
            stop(a);
            if (m.dx < n.taunt_from) return goToDepth(a);
            m.timer = n.stroll_ticks;
            m.walk = .taunt;
            return faceAndShow(a, .taunt);
        }
        m.timer = n.back_away_ticks;
        a.entity.velocity.x = if (m.left_of) n.back_away_speed else n.back_away_speed.neg();
    }
    m.timer -%= 1;
    a.entity.velocity.depth = keepAbove(a);
    move(a);
}

/// A taunt, then he strolls: away from a target nearer than a while, toward a farther one.
fn taunt(a: Actor, near: bool) void {
    const n = a.numbers();
    const m = a.mind;
    m.timer -%= 1;
    if (m.timer != 0) return;
    if (near) return rest(a);
    var speed = n.stroll_speed;
    if (m.dx >= n.stroll_toward_from) speed = speed.neg();
    if (!m.left_of) speed = speed.neg();
    strollOn(a, speed, .stroll, .walk);
}

/// He walks across at `speed`, a stroll's while, as `way`, in animation `which`.
fn strollOn(a: Actor, speed: Fixed, way: Walk, which: Animation) void {
    const m = a.mind;
    stop(a);
    a.entity.velocity.x = speed;
    m.timer = a.numbers().stroll_ticks;
    m.walk = way;
    faceAndShow(a, which);
}

fn stroll(a: Actor, near: bool) void {
    const n = a.numbers();
    const m = a.mind;
    m.timer -%= 1;
    if (m.timer != 0) {
        sway(a);
        return edgeMove(a);
    }
    if (near) return rest(a);
    stop(a);
    if (m.dx >= n.stand_near) return goToDepth(a);
    m.timer = n.stroll_ticks;
    m.walk = .stand;
    faceAndShow(a, .idle);
}

fn stand(a: Actor, near: bool) void {
    const n = a.numbers();
    const m = a.mind;
    m.timer -%= 1;
    if (m.timer != 0) return edgeMove(a);
    if (near) return rest(a);
    var speed = if (m.dd >= n.stand_far_level) n.stand_far_speed else n.stroll_speed;
    if (m.left_of) speed = speed.neg();
    strollOn(a, speed, .approach, .walk);
}

fn approach(a: Actor, near: bool) void {
    const m = a.mind;
    m.timer -%= 1;
    if (m.timer != 0) {
        sway(a);
        return edgeMove(a);
    }
    if (near) return rest(a);
    goToDepth(a);
}

/// He stops, and goes to his target's depth from his next tick.
fn goToDepth(a: Actor) void {
    const m = a.mind;
    stop(a);
    a.entity.velocity.depth = if (m.above) a.numbers().align_speed.neg() else a.numbers().align_speed;
    m.walk = .level;
}

/// At the depths' ends he turns back; level with his target he stops and throws his boomerang.
fn alignDepth(a: Actor, near: bool) void {
    const n = a.numbers();
    const m = a.mind;
    if (near) return rest(a);
    const d = a.entity.position.depth.whole();
    if (d == 0 or d == n.depth_most) {
        a.entity.velocity.depth = a.entity.velocity.depth.neg();
        return edgeMove(a);
    }
    if (m.dd >= n.align_level) return edgeMove(a);
    stop(a);
    m.timer = n.throw_ticks;
    m.walk = .throw;
    faceAndShow(a, .throw);
}

/// The throw (his boomerang leaves his hand at its frame that holds it out: boomerang.zig);
/// then he waits.
fn throwBoomerang(a: Actor) void {
    const m = a.mind;
    m.timer -%= 1;
    if (m.timer != 0) return edgeMove(a);
    m.walk = .wait;
    faceAndShow(a, .wait);
}

/// He waits for his boomerang: his target near, he gives up; his target's back turned near and
/// level, he charges; his boomerang coming back, he walks up to its depth and catches it at his
/// hand.
fn waitForBoomerang(a: Actor, t: *const Entity, near: bool) void {
    const n = a.numbers();
    const m = a.mind;
    if (near) return rest(a);
    const back_turned = if (m.left_of) t.facing == .left else t.facing == .right;
    if (back_turned and m.dx < n.charge_back_from and m.dd < n.charge_back_level) return charge(a);
    const b = boomerangIn(a) orelse return rest(a);
    const coming = a.tick.actor(@import("boomerang.zig"), b) orelse return edgeMove(a);
    if (coming.mind.state != .back) return edgeMove(a);
    const d = a.entity.position.depth.whole();
    const to = coming.mind.point_depth;
    a.entity.velocity.depth = if (d > to) n.catch_steer.neg() else if (d < to) n.catch_steer else .zero;
    const hand = a.entity.position.x.whole() + @as(i32, n.catch_hand) * a.entity.facing.sign();
    if (@abs(hand - coming.entity.position.x.whole()) >= n.catch_within) return edgeMove(a);
    coming.remove();
    rest(a);
}

fn charging(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (m.dx >= n.charge_stop_far or (m.dx < n.charge_stop_near and m.dd >= n.charge_stop_level)) {
        a.entity.velocity.x = .zero;
        m.walk = .decide;
    }
    a.entity.velocity.depth = toLevel(a);
    move(a);
}

/// Once on the screen he walks on a while, then stops across.
fn walkingIn(a: Actor) void {
    const m = a.mind;
    m.walk_in -%= 1;
    if (m.walk_in == 0) {
        m.walk = .decide;
        a.entity.velocity.x = .zero;
    }
    move(a);
}

/// He stands, deciding afresh.
fn rest(a: Actor) void {
    const m = a.mind;
    m.walk = .decide;
    m.timer = 0;
    faceAndShow(a, .stand);
}

/// His sway in depth: down a while, up a while, again.
fn sway(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.sway +%= 1;
    var speed = n.sway_speed;
    if (m.sway >= n.zigzag_turn) {
        if (m.sway < n.zigzag_back) speed = speed.neg() else m.sway = 0;
    }
    a.entity.velocity.depth = speed;
}

/// His speed in depth keeping a little above his target.
fn keepAbove(a: Actor) Fixed {
    const n = a.numbers();
    const m = a.mind;
    if (m.above) return n.steer_fast.neg();
    const d = m.dd;
    if (d >= n.keep_far) return n.steer_fast;
    if (d < n.keep_near) return n.steer_fast.neg();
    if (d >= n.keep_step_2) return n.steer;
    if (d >= n.keep_step_1) return n.steer_slow;
    if (d >= n.keep_at) return .zero;
    return n.steer_slow.neg();
}

/// His speed in depth toward his target's.
fn toLevel(a: Actor) Fixed {
    const n = a.numbers();
    const m = a.mind;
    const d = m.dd;
    const speed: Fixed = if (d >= n.level_far) n.steer_fast else if (d >= n.level_mid) n.steer else if (d >= n.level_near) n.steer_slow else .zero;
    return if (m.above) speed.neg() else speed;
}

/// Far out of the screen he is brought back to its edge; out of it he is slowed; he moves.
fn edgeMove(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    const d = a.mind.drawn;
    if (d <= n.edge_from) {
        e.position.x = e.position.x.add(.pixels(n.edge_from - d));
    } else if (d > n.edge_to) {
        e.position.x = e.position.x.add(.pixels(n.edge_to - d));
    }
    if (d < n.push_from) {
        e.velocity.x = e.velocity.x.add(.pixels(1));
    } else if (d >= n.push_to) {
        e.velocity.x = e.velocity.x.sub(.pixels(1));
    }
    move(a);
}

/// His boomerang, while it is one: the thing in its place in the world.
fn boomerangIn(a: Actor) ?Handle {
    const at = a.mind.boomerang orelse return null;
    const h = a.tick.world.handleAt(at) orelse return null;
    if (a.tick.actor(@import("boomerang.zig"), h) == null) return null;
    return h;
}

/// Without his boomerang in hand he gets another (the one flying flies on): the place he knows
/// is empty, or what is there has left its first state.
fn supplyBoomerang(a: Actor) void {
    const m = a.mind;
    if (m.boomerang) |at| {
        const there = &a.tick.world.entities[at];
        if (there.alive() and behaviours.stateIndex(&there.mind) == 0) return;
    }
    const kind = a.tick.kinds.find(boomerang_kind) orelse return;
    const h = a.tick.world.spawnWithin(a.tick.kinds, kind, a.handle.index + 1, 51, .zero, .right) catch return;
    m.boomerang = @intCast(h.index);
    if (a.tick.actor(@import("boomerang.zig"), h)) |b| b.mind.* = .{ .thrower = @intCast(a.handle.index), .power = m.power, .ground = m.ground };
}

// The swing ----------------------------------------------------------------------------------

/// His swing: at its last frame he walks again.
fn swing(a: Actor) void {
    if (a.frame() != a.numbers().swing_ends) return;
    a.endMove();
    walkAgain(a);
}

/// He walks again, facing his target, standing.
fn walkAgain(a: Actor) void {
    a.mind.state = .walk;
    a.endMove();
    faceAndShow(a, .stand);
}

// Blows ----------------------------------------------------------------------------------------

/// A blow meets him: walking, swinging or held, on the screen, a player's blow costs him its
/// damage at his next tick (knocking him down when it does); a thing thrown or swung (but by a
/// hand), a weapon's power or a body's, and it knocks down. His own blow does not land at this
/// tick.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    const n = a.numbers();
    const m = a.mind;
    switch (m.state) {
        .walk, .swing, .held => {},
        else => return false,
    }
    if (m.ended) return false;
    const sx = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
    if (sx < n.struck_from or sx >= n.struck_to) return false;
    a.endMove();
    if (blow.missile) {
        const thing = a.other(blow.attacker);
        const weapon = if (thing) |x| a.tick.kindOf(x).family() == .weapon else false;
        m.damage = if (weapon) @intCast(@min(blow.damage, 255)) else n.missile_damage;
        m.attacker = if (thing) |x| if (x.missile) |mi| mi.by else blow.attacker else blow.attacker;
        m.knocks_down = true;
        a.sound(.hurt);
        return true;
    }
    m.damage = @intCast(@min(blow.damage, 255));
    m.attacker = blow.attacker;
    m.knocks_down = blow.reaction == .knock_down;
    return true;
}

/// The damage of a blow met at the last tick: he stops; his last health, a blow that knocks
/// down, or one in the air knocks him down (out of a hold); else he is knocked back (held, he
/// stays so, facing his holder). Returns whether he took one.
fn takeDamage(a: Actor) bool {
    const n = a.numbers();
    const m = a.mind;
    if (m.damage == 0) return false;
    const d = m.damage;
    m.damage = 0;
    stop(a);
    a.takeDamage(m.attacker, d);
    var from = m.attacker;
    if (a.entity.health <= 0) {
        beatenCry(a);
        breakHold(a);
        knockDown(a, from, n.knock_down_ticks);
        return true;
    }
    a.sound(.hurt);
    const knocks = m.knocks_down;
    m.knocks_down = false;
    if (knocks or !grounded(a)) {
        breakHold(a);
        knockDown(a, from, n.knock_down_ticks);
        return true;
    }
    if (m.hold.grabbed) from = m.holder;
    knocked(a, from, n.knock_back_ticks);
    return true;
}

/// Knocked down: flying back from `from`, up, to bounce.
fn knockDown(a: Actor, from: ?Handle, ticks: u8) void {
    const n = a.numbers();
    a.entity.velocity.x = n.knocked_x;
    a.entity.velocity.height = n.knocked_up;
    a.mind.bounces = n.knocked_bounces;
    knocked(a, from, ticks);
}

/// Knocked back (or down) `ticks` ticks, facing `from` (his speed across away from it); held from
/// behind, facing away.
fn knocked(a: Actor, from: ?Handle, ticks: u8) void {
    const m = a.mind;
    const e = a.entity;
    m.count = ticks;
    m.state = .knocked_back;
    m.walk = .decide;
    a.endMove();
    e.facing = .right;
    if (from) |h| if (a.other(h)) |o| if (o.position.x.whole() < e.position.x.whole()) {
        e.facing = .left;
        e.velocity.x = e.velocity.x.neg();
    };
    if (m.hold.behind) e.facing = e.facing.turned();
    move(a);
    a.animate(.knocked);
}

/// Out of a hold: his holder lets him go.
fn breakHold(a: Actor) void {
    const m = a.mind;
    if (@as(u8, @bitCast(m.hold)) == 0) return;
    m.hold = .{};
    if (a.entity.holder != null) a.letGo();
}

/// The cry of his last health; with no twin left, the round's timer stops.
fn beatenCry(a: Actor) void {
    const m = a.mind;
    const alone = m.twin == 0 or if (twinOf(a)) |o| o.entity.health <= 0 else true;
    if (alone) a.tick.world.timer.stopped = true;
    a.sound(.cry);
}

/// Knocked back: he shakes where he stands, or flies, bounces and lands; out of time, held still
/// he stays so, else he walks, or (down from a fall) lies.
fn knockedBackTick(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (m.attacker) |h| if (a.other(h)) |o| measure(a, o, false);
    if (m.bounces != 0) {
        if (!e.position.height.eql(m.ground)) {
            e.velocity.height = e.velocity.height.add(n.knocked_gravity);
            if (e.velocity.height.raw == 0 and m.bounces == 2) a.animate(.flight);
        } else {
            m.bounces -= 1;
            if (m.bounces == 0) {
                e.velocity.x = .zero;
                e.velocity.height = .zero;
            } else {
                e.velocity.height = n.bounce_up;
                a.animate(.bounce);
            }
            a.sound(.thud);
        }
    } else if (a.plays(.knocked)) {
        const by: i32 = if (m.count & 1 != 0) -n.shake else n.shake;
        e.position.x = e.position.x.add(.pixels(by));
    }
    m.count -%= 1;
    if (m.count != 0) return move(a);
    if (@as(u8, @bitCast(m.hold)) != 0) {
        m.state = .held;
        return a.animate(if (m.hold.front) .held else .held_behind);
    }
    if (a.plays(.knocked)) return walkAgain(a);
    lie(a);
}

/// Down: alive, a moment; beaten, much longer, blinking at first, and his points go to the
/// player who struck him last; the round is won (with no twin) when it is over.
fn lie(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.hold = .{};
    m.state = .down;
    if (a.entity.health > 0) {
        m.count = n.down_ticks;
        return faceAndShow(a, .down);
    }
    m.count = n.dead_ticks;
    if (m.twin == 0) return;
    const other = twinOf(a) orelse return;
    if (other.entity.health > 0 or m.twin_beaten) return;
    other.mind.twin_beaten = true;
    a.tick.roundWon();
}

fn down(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (a.entity.health > 0) {
        m.count -%= 1;
        if (m.count == 0) walkAgain(a);
        return;
    }
    a.entity.flags.hidden = true;
    m.count -%= 1;
    if (m.count == 0) {
        if (m.twin == 0) a.tick.roundWon();
        return a.remove();
    }
    if (m.count == n.points_at) return scorePoints(a);
    if (m.count > n.points_at and m.count & 2 != 0) a.entity.flags.hidden = false;
}

/// His points to the player who struck him last: player 1, else player 2.
fn scorePoints(a: Actor) void {
    const w = a.tick.world;
    const by_first = if (a.mind.attacker) |h| if (w.players[0].entity) |p| p.eql(h) else false else false;
    const p = &w.players[if (by_first) 0 else 1];
    p.score = @min(p.score +| a.numbers().points, w.score_most);
}

// Holds ----------------------------------------------------------------------------------------

/// Walking, swinging or held, a player's reach meets him within his height: the grab takes him
/// (not one another holds).
pub fn grabbable(a: Actor, by: Handle) bool {
    const m = a.mind;
    switch (m.state) {
        .walk, .swing, .held => {},
        else => return false,
    }
    if (m.ended) return false;
    if (m.hold.grabbed) if (m.holder) |h| if (!h.eql(by)) return false;
    const holder = a.other(by) orelse return false;
    return @abs(holder.position.height.whole() - a.entity.position.height.whole()) <= a.numbers().grab_height;
}

/// A grab took him: from his next tick, his holder's state says what it does to him.
pub fn heldBy(a: Actor, holder: Handle) void {
    a.endMove();
    const m = a.mind;
    if (m.hold.grabbed) return;
    m.hold.grabbed = true;
    m.holder = holder;
}

/// His holder let him go.
pub fn letGoBy(a: Actor, holder: Handle) void {
    _ = holder;
    a.mind.let_go = true;
}

/// What his holder's state does to him.
const Reaction = enum { release, front, behind, knee, last_knee, toss, vault, fling, nothing };

fn reactionOf(a: Actor, holder: *const Entity) Reaction {
    const name = behaviours.stateName(&holder.mind) orelse return .release;
    _ = a;
    const table = [_]struct { []const u8, Reaction }{
        .{ "grab", .front },
        .{ "grab_behind", .behind },
        .{ "knee", .knee },
        .{ "knee_last", .last_knee },
        .{ "grab_blow", .toss },
        .{ "vault", .vault },
        .{ "vault_land", .vault },
        .{ "throw", .nothing },
        .{ "throw_back", .nothing },
    };
    for (table) |r| if (std.mem.eql(u8, r[0], name)) return r[1];
    return .release;
}

/// Grabbed, what his holder does to him now: holds him in front or from behind (placed once);
/// knees him (the damage at his next tick); throws him; or lets him go (placed, he walks).
/// Returns whether his tick ended there.
fn holdTaken(a: Actor) bool {
    const n = a.numbers();
    const m = a.mind;
    if (!m.hold.grabbed) return false;
    const hh = m.holder orelse return release(a);
    const holder = a.other(hh) orelse return release(a);
    switch (reactionOf(a, holder)) {
        .release => return release(a),
        .nothing => return false,
        .knee => {
            m.damage = n.knee_damage;
            m.attacker = hh;
            return false;
        },
        .last_knee => {
            m.knocks_down = true;
            m.damage = n.last_knee_damage;
            m.attacker = hh;
            return false;
        },
        .front => {
            if (m.hold.front) return false;
            m.hold = .{ .grabbed = true, .front = true };
            placeFacing(a, holder, n.hold_front);
            return heldNow(a, .held);
        },
        .behind => {
            if (m.hold.behind) return false;
            m.hold = .{ .grabbed = true, .behind = true };
            placeBacking(a, holder, n.hold_behind);
            return heldNow(a, .held_behind);
        },
        .toss => {
            if (m.hold.thrown) return false;
            m.hold = .{ .grabbed = true, .thrown = true };
            placeBacking(a, holder, n.toss_place);
            return thrown(a, .tossed, .held, n.toss_ticks);
        },
        .vault => {
            if (m.hold.thrown) return false;
            m.hold = .{ .grabbed = true, .thrown = true };
            placeBacking(a, holder, n.vault_place);
            return thrown(a, .vaulted, .held_behind, n.vault_ticks);
        },
        .fling => {
            m.hold = .{ .grabbed = true, .thrown = true };
            placeFacing(a, holder, n.fling_place);
            return thrown(a, .flung, .held, n.fling_ticks);
        },
    }
}

/// Let go: placed in the hold, he walks again at once.
fn release(a: Actor) bool {
    const m = a.mind;
    const placed = m.hold.placed();
    m.hold = .{};
    if (!placed) return false;
    walkAgain(a);
    return true;
}

/// Held: he stands in his hold's pose, still.
fn heldNow(a: Actor, which: Animation) bool {
    const m = a.mind;
    m.walk = .decide;
    m.state = .held;
    stop(a);
    a.animate(which);
    return true;
}

/// Thrown: a thing thrown by his holder, in the throw's state, for `ticks` ticks.
fn thrown(a: Actor, state: State, which: Animation, ticks: u8) bool {
    const n = a.numbers();
    const m = a.mind;
    m.state = state;
    m.count = ticks;
    m.bounces = n.thrown_bounces;
    a.animate(which);
    stop(a);
    if (m.holder) |h| a.entity.missile = .{ .by = h, .damage = n.thrown_damage };
    return true;
}

/// Placed `ahead` in front of his holder, facing it; on its depth, on his ground.
fn placeFacing(a: Actor, holder: *const Entity, ahead: i16) void {
    const e = a.entity;
    e.facing = .right;
    if (holder.facing == .right) {
        e.facing = .left;
        e.position.x = holder.position.x.add(.pixels(ahead));
    } else e.position.x = holder.position.x.sub(.pixels(ahead));
    e.position.depth = holder.position.depth;
    e.position.height = a.mind.ground;
}

/// Placed `back` behind where his holder faces (ahead of it, negative), his back to it.
fn placeBacking(a: Actor, holder: *const Entity, back: i16) void {
    const e = a.entity;
    e.facing = .right;
    if (holder.facing == .left) {
        e.facing = .left;
        e.position.x = holder.position.x.add(.pixels(back));
    } else e.position.x = holder.position.x.sub(.pixels(back));
    e.position.depth = holder.position.depth;
    e.position.height = a.mind.ground;
}

/// Held: let go by his holder he walks; his hold ended otherwise, he walks.
fn held(a: Actor) void {
    const m = a.mind;
    if (m.let_go) {
        m.let_go = false;
        m.hold = .{};
        return walkAgain(a);
    }
    if (m.state != .held) return;
    if (!m.hold.grabbed) walkAgain(a);
}

// Thrown ---------------------------------------------------------------------------------------

/// The thrower's side: whether it faces left.
fn throwerLeft(a: Actor) bool {
    const h = a.mind.holder orelse return false;
    const t = a.other(h) orelse return false;
    return t.facing == .left;
}

/// A landing's shake of the screen, with its thud, unless the screen shakes already.
fn landingShake(a: Actor) void {
    const c = &a.tick.world.camera;
    if (a.tick.world.special or c.shake != 0) return;
    a.tick.shake();
    a.sound(.thud);
}

/// His fall after a throw: in the air, faster down; landing, his bounces: the first `first`
/// back up (a shake of the screen when `shake_first`, else a thud); the second halves his speed
/// across, `second` up, with the throw's `damage` (the shake then, or a thud); the last stops
/// him.
fn thrownFall(a: Actor, first: Fixed, second: Fixed, damage: u8, shake_first: bool) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (!grounded(a)) {
        e.velocity.height = e.velocity.height.add(n.thrown_gravity);
        return;
    }
    m.bounces -= 1;
    if (m.bounces == 0) {
        e.velocity.x = .zero;
        e.velocity.height = .zero;
        return a.sound(.thud);
    }
    if (m.bounces == 1) {
        if (!shake_first) landingShake(a);
        e.velocity.x = .{ .raw = e.velocity.x.raw >> 1 };
        e.velocity.height = .parts(@intCast(second.whole()), e.velocity.height.frac());
        a.takeDamage(m.holder, damage);
        if (e.health <= 0) return beatenCry(a);
        if (shake_first) a.sound(.thud);
        return;
    }
    e.velocity.height = .parts(@intCast(first.whole()), e.velocity.height.frac());
    a.animate(.bounce);
    if (shake_first) landingShake(a) else a.sound(.thud);
}

/// The throw's ticks run out: he is no longer a thing thrown, and lies.
fn thrownCount(a: Actor) void {
    const m = a.mind;
    m.count -%= 1;
    if (m.count != 0) return move(a);
    a.entity.missile = null;
    lie(a);
}

/// Tossed over the shoulder: lifted, flying over, then he falls and bounces.
fn tossed(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (m.bounces != 0) {
        const left = m.count;
        if (left == n.toss_lift_at) {
            a.animate(.lifted);
            e.velocity.height = .parts(@intCast(n.toss_up.whole()), e.velocity.height.frac());
            e.position.height = e.position.height.sub(.pixels(n.toss_lift));
            var x = n.toss_x.whole();
            var ahead: i32 = n.toss_ahead;
            if (throwerLeft(a)) {
                x = -x;
                ahead = -ahead;
                e.facing = .left;
            }
            e.velocity.x = .parts(@intCast(x), e.velocity.x.frac());
            e.position.x = e.position.x.add(.pixels(ahead));
        } else if (left < n.toss_lift_at) {
            thrownFall(a, n.toss_bounce, n.toss_bounce_2, n.toss_damage, true);
        }
    }
    thrownCount(a);
}

/// Carried over the thrower's head step by step (`carried`), slammed down (the vault's damage),
/// then flying off and sliding.
fn vaulted(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (m.bounces != 0) {
        const left = m.count;
        var step: ?usize = null;
        if (left == n.vault_turn_at) {
            step = 0;
            a.animate(.flight);
        } else if (left == n.vault_over_at) {
            step = 1;
        } else if (left == n.vault_down_at) {
            a.takeDamage(m.holder, n.vault_damage);
            if (e.health <= 0) beatenCry(a);
            landingShake(a);
            a.animate(.lifted);
            step = 2;
        }
        if (step) |k| {
            var back: i32 = a.tables().carried[2 * k];
            const below: i32 = a.tables().carried[2 * k + 1];
            m.bounces -= 1;
            if (throwerLeft(a)) {
                back = -back;
                e.facing = .left;
            }
            e.position.x = e.position.x.sub(.pixels(back));
            e.position.height = e.position.height.add(.pixels(below));
        }
    }
    const left = m.count;
    if (left == n.vault_fly_at) {
        e.velocity.x = n.vault_fly;
        e.velocity.height = n.vault_fly;
        a.sound(.thud);
        if (e.facing == .left) e.velocity.x = e.velocity.x.neg();
    } else if (left < n.vault_fly_at) {
        if (!grounded(a)) {
            e.velocity.height = e.velocity.height.add(n.thrown_gravity);
        } else if (e.velocity.x.raw != 0) {
            if (a.plays(.bounce)) {
                e.velocity = .zero;
            } else {
                e.facing = if (m.left_of) .right else .left;
                a.animate(.bounce);
                e.velocity.x = n.vault_slide;
                e.velocity.height = n.vault_slide;
                a.sound(.thud);
                if (e.facing == .left) e.velocity.x = e.velocity.x.neg();
            }
        }
    }
    thrownCount(a);
}

/// Flung behind the thrower: swung to its back, flying off, falling and bouncing.
fn flung(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (m.bounces != 0) {
        const left = m.count;
        if (left == n.fling_lift_at or left == n.fling_at) {
            const k: usize = if (left == n.fling_lift_at) 3 else 4;
            var x: i32 = 0;
            if (left == n.fling_lift_at) {
                a.animate(.lifted);
            } else {
                e.velocity.height = .parts(@intCast(n.fling_up.whole()), e.velocity.height.frac());
                x = n.fling_x.whole();
            }
            var back: i32 = a.tables().carried[2 * k];
            const below: i32 = a.tables().carried[2 * k + 1];
            if (!throwerLeft(a)) {
                back = -back;
                x = -x;
                e.facing = .left;
            }
            e.position.x = e.position.x.add(.pixels(back));
            e.position.height = e.position.height.add(.pixels(below));
            e.velocity.x = .parts(@intCast(x), e.velocity.x.frac());
        } else if (left < n.fling_at) {
            if (left == n.fling_turn_at) a.animate(.flight);
            thrownFall(a, n.fling_bounce, n.fling_bounce_2, n.fling_damage, false);
        }
    }
    thrownCount(a);
}

// Taken up from a situation ------------------------------------------------------------------

/// Taken up from a situation another program recorded, `elapsed` ticks into his state: his
/// ground (the round's), his power, the status bar, his boomerangs; drawn where he is; his
/// state's timers gone down by then; walking, his way by his speeds (`takeUpSince` the rest).
pub fn takeUp(a: Actor, elapsed: u32) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const w = a.tick.world;
    if (m.state == .appear) return;
    m.ground = w.ground;
    m.power = strength(a).power;
    e.power = m.power;
    m.drawn = @intCast(e.position.x.whole() - w.camera.x.whole());
    onBar(a);
    takeUpBoomerangs(a);
    const ago: u8 = @intCast(@min(elapsed, 255));
    switch (m.state) {
        .walk => takeUpWalk(a),
        .swing => a.startMove(.swing),
        .knocked_back => {
            m.attacker = e.struck_by;
            const flying = e.velocity.x.raw != 0 or e.velocity.height.raw != 0 or !grounded(a);
            m.bounces = if (flying) n.knocked_bounces else 0;
            m.count = (if (flying) n.knock_down_ticks else n.knock_back_ticks) -| ago;
        },
        .down => {
            m.attacker = e.struck_by;
            m.count = (if (e.health > 0) n.down_ticks else n.dead_ticks) -| ago;
        },
        .special_still => {
            m.attacker = e.struck_by;
            m.special_left = n.special_ticks -| @as(u16, @intCast(@min(elapsed, std.math.maxInt(u16))));
            m.grounded_in = n.special_grounded -| ago;
            m.special_taken = true;
        },
        else => {},
    }
}

/// His way of walking by his speeds: in at the walk in's (counting down since he came on the
/// screen), charging, backing away; across at a stroll's; in depth only, going to his target's
/// depth (or stopped at the walk in's end); else as his animation says.
fn takeUpWalk(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const vx = a.entity.velocity.x.abs();
    const vd = a.entity.velocity.depth.abs();
    m.walk = .decide;
    if (vx.eql(n.walk_in_speed) and vd.eql(n.walk_in_speed)) {
        m.walk = .walk_in;
        var on: u8 = 0;
        var d: i32 = m.drawn;
        while (d >= n.on_screen_from and d < n.on_screen_to and on < 255) : (on += 1) d -= a.entity.velocity.x.whole();
        m.walk_in = n.walk_in_ticks -| on;
    } else if (vx.eql(n.charge_speed)) {
        m.walk = .charge;
    } else if (vx.eql(n.back_away_speed)) {
        m.walk = .decide;
    } else if (vx.raw != 0) {
        m.walk = .stroll;
    } else if (vd.eql(n.align_speed)) {
        m.walk = .level;
    } else if (a.plays(.taunt)) {
        m.walk = .taunt;
    } else if (a.plays(.idle)) {
        m.walk = .stand;
    } else if (a.plays(.throw)) {
        m.walk = .throw;
    } else if (a.plays(.wait)) {
        m.walk = .wait;
    }
}

/// Taken up walking: his speed across has been what it is `across_ago` ticks, his animation
/// `pose_ago` ticks; his way's timer gone down by then.
pub fn takeUpSince(a: Actor, across_ago: u32, pose_ago: u32) void {
    const n = a.numbers();
    const m = a.mind;
    if (m.state != .walk) return;
    const across: u8 = @intCast(@min(across_ago, 255));
    const pose: u8 = @intCast(@min(pose_ago, 255));
    m.timer = switch (m.walk) {
        .decide => if (a.entity.velocity.x.raw != 0) n.back_away_ticks -| (across +| 1) else 0,
        .stroll => n.stroll_ticks -| across,
        .taunt, .stand => n.stroll_ticks -| pose,
        .throw => n.throw_ticks -| pose,
        else => 0,
    };
}

/// His boomerangs are his: the one in hand his own (else the last), each with his power, from
/// his ground.
fn takeUpBoomerangs(a: Actor) void {
    const m = a.mind;
    const B = @import("boomerang.zig");
    var own: ?u8 = null;
    for (&a.tick.world.entities, 0..) |*o, i| {
        if (!o.alive()) continue;
        const h = a.tick.world.handleAt(i) orelse continue;
        const b = a.tick.actor(B, h) orelse continue;
        b.mind.thrower = @intCast(a.handle.index);
        b.mind.power = m.power;
        b.mind.ground = m.ground;
        if (b.mind.state == .out or b.mind.state == .back) b.entity.missile = .{ .by = a.handle, .damage = m.power };
        if (b.mind.state == .in_hand or own == null) own = @intCast(i);
    }
    m.boomerang = own;
}

/// Taken up, a blow of `by` met him at the situation's tick: its damage at his next tick,
/// knocking him down when it does (a thing thrown, or a blow that knocks down).
pub fn takeUpMet(a: Actor, by: Handle, damage: i16) void {
    const m = a.mind;
    switch (m.state) {
        .walk, .swing, .held => {},
        else => return,
    }
    m.damage = @intCast(std.math.clamp(damage, 0, 255));
    m.attacker = by;
    const s = a.other(by) orelse return;
    if (s.missile != null) {
        m.knocks_down = true;
        m.attacker = s.missile.?.by;
        return;
    }
    const blow = s.move orelse return;
    m.knocks_down = a.tick.kindOf(s).definition.moves[blow].reaction == .knock_down;
}

/// Taken up held: in front of his holder when he faces it, else from behind.
pub fn takeUpHeld(a: Actor, elapsed: u32) void {
    _ = elapsed;
    const m = a.mind;
    const hh = a.entity.holder orelse return;
    const holder = a.other(hh) orelse return;
    m.hold = .{ .grabbed = true };
    m.holder = hh;
    if (holder.facing != a.entity.facing) m.hold.front = true else m.hold.behind = true;
}

// The special attack and a player's new life -----------------------------------------------------

/// A player called the special attack.
pub fn specialCalled(a: Actor) void {
    a.mind.special_new = true;
}

/// At a special attack's first tick he takes it once: held still a while (longer for the second
/// player's), then knocked down with its damage. Returns whether his tick ended there.
fn special(a: Actor) bool {
    const n = a.numbers();
    const m = a.mind;
    const w = a.tick.world;
    if (!w.special) {
        m.special_taken = false;
        m.special_new = false;
        return false;
    }
    if (m.special_new) {
        m.special_new = false;
        m.special_taken = false;
    }
    if (m.state == .appear or m.special_taken) return false;
    m.special_taken = true;
    if (m.state == .special_still or a.entity.health <= 0) return false;
    const second = if (w.special_by) |by| if (w.players[1].entity) |p| p.eql(by) else false else false;
    m.attacker = w.players[if (second) 1 else 0].entity;
    m.grounded_in = n.special_grounded;
    m.state = .special_still;
    a.endMove();
    a.pause(true);
    m.special_left = if (second) n.special_ticks_second else n.special_ticks;
    m.hold = .{};
    m.walk = .decide;
    return true;
}

/// Held still by the special attack; put back on the ground a moment in; at its end its damage,
/// and he is knocked down (dying, faster).
fn specialStill(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (m.special_left != 0) {
        m.special_left -= 1;
        if (m.grounded_in == 0) return;
        m.grounded_in -= 1;
        if (m.grounded_in != 0) return;
        a.entity.position.height = m.ground;
        a.animate(.stand);
        return;
    }
    a.takeDamage(m.attacker, n.special_damage);
    if (a.entity.health > 0) {
        a.entity.velocity.x = n.blast_x;
    } else {
        beatenCry(a);
        a.entity.velocity.x = n.dying_x;
    }
    a.entity.velocity.height = n.blast_up;
    knockedFlat(a);
}

/// A player's new life drops in: at his tick it knocks him down.
pub fn knockedBack(a: Actor) void {
    a.mind.blast = true;
}

/// A player's new life knocks him down when he walks, swings or is held still: facing left, his
/// health spared. Returns whether his tick ended there.
fn blast(a: Actor) bool {
    const n = a.numbers();
    const m = a.mind;
    if (!m.blast) return false;
    m.blast = false;
    switch (m.state) {
        .walk, .swing, .special_still => {},
        else => return false,
    }
    a.entity.facing = .left;
    a.entity.velocity.x = n.blast_x;
    a.entity.velocity.height = n.blast_up;
    knockedFlat(a);
    return true;
}

/// Knocked down where he is (the special attack's, a new life's): flying back the way he faces
/// is not, up, to bounce.
fn knockedFlat(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    e.velocity.depth = .zero;
    m.bounces = n.blast_bounces;
    m.count = n.blast_ticks;
    m.state = .knocked_back;
    m.walk = .decide;
    a.endMove();
    if (e.facing == .left) e.velocity.x = e.velocity.x.neg();
    if (m.left_of) e.facing = .left;
    a.animate(.knocked);
    move(a);
}
