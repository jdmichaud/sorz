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
const boss = @import("boss.zig");
const C = boss.Of(@This());

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
    peppered,
    special_still,
};

/// The traces' names of his states that are not theirs.
pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "throw", .state = .swing },
    .{ .name = "thrown6", .state = .tossed },
    .{ .name = "thrown7", .state = .vaulted },
    .{ .name = "thrown8", .state = .flung },
    .{ .name = "struck_by_bottle", .state = .peppered },
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
    hold: boss.Hold = .{},
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

pub const Animation = enum { stand, swing, knocked, held, held_behind, flight, bounce, down, lifted, flinch, idle, walk, taunt, throw, wait };
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
    pepper_ticks: u8,
    blast_x: Fixed,
    blast_up: Fixed,
    dying_x: Fixed,
    blast_ticks: u8,
    blast_bounces: u8,
};

/// His walk from its start (the body's resets).
pub fn walkAfresh(a: Actor) void {
    a.mind.walk = .decide;
}

// The body's hooks --------------------------------------------------------------------------------

pub const struck = C.struck;
pub const grabbable = C.grabbable;
pub const heldBy = C.heldBy;
pub const letGoBy = C.letGoBy;
pub const takeUpMet = C.takeUpMet;
pub const takeUpHeld = C.takeUpHeld;
pub const specialCalled = C.specialCalled;
pub const knockedBack = C.knockedBack;

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
    if (C.special(a)) return C.end(a);
    if (C.blast(a)) return C.end(a);
    switch (m.state) {
        .appear => {
            appear(a);
            C.end(a);
        },
        .walk => {
            m.let_go = false;
            const t = chooseTarget(a) orelse return C.end(a);
            m.target = t;
            m.unattackable = !a.tick.attackable(t);
            C.measure(a, a.other(t).?, true);
            if (C.takeDamage(a) or C.holdTaken(a)) C.end(a);
        },
        .swing => {
            m.let_go = false;
            if (C.takeDamage(a) or C.holdTaken(a)) C.end(a);
        },
        .held => {
            if (m.holder) |h| if (a.other(h)) |holder| C.measure(a, holder, false);
            if (C.takeDamage(a) or C.holdTaken(a)) C.end(a);
        },
        .peppered => if (C.takeDamage(a) or C.holdTaken(a)) C.end(a),
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
        .held => C.held(a),
        .knocked_back => C.knockedBackTick(a),
        .down => C.down(a),
        .tossed => C.tossed(a),
        .vaulted => C.vaulted(a),
        .flung => C.flung(a),
        .peppered => C.pepperedTick(a),
        .special_still => C.specialStill(a),
    };
    if (!a.entity.alive()) return;
    // Where he is drawn at the tick's end.
    if (!a.entity.flags.hidden) m.drawn = @intCast(a.entity.position.x.whole() - a.tick.world.camera.x.whole());
}

// Coming in ----------------------------------------------------------------------------------

/// His first tick: shown (the round's script places its enemies hidden, and he comes in seen);
/// the ground he stands on is his; his twin found; the status bar shows him; his power and
/// health by the level; he walks.
fn appear(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    e.flags.hidden = false;
    m.ground = e.position.height;
    C.pairUp(a);
    if (C.inFight(a)) C.onBar(a);
    const s = C.strength(a);
    m.power = s.power;
    e.power = s.power;
    e.health = s.health;
    m.state = .walk;
    m.walk = .decide;
    e.facing = .right;
    a.animate(.stand);
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
        if (!a.plays(.walk)) C.faceAndShow(a, .walk);
        return C.move(a);
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
    if (!(a.plays(.stand) and a.entity.facing == .right)) C.faceAndShow(a, .stand);
    C.move(a);
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
            C.stop(a);
            if (m.dx < n.taunt_from) return goToDepth(a);
            m.timer = n.stroll_ticks;
            m.walk = .taunt;
            return C.faceAndShow(a, .taunt);
        }
        m.timer = n.back_away_ticks;
        a.entity.velocity.x = if (m.left_of) n.back_away_speed else n.back_away_speed.neg();
    }
    m.timer -%= 1;
    a.entity.velocity.depth = C.keepAbove(a);
    C.move(a);
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
    C.stop(a);
    a.entity.velocity.x = speed;
    m.timer = a.numbers().stroll_ticks;
    m.walk = way;
    C.faceAndShow(a, which);
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
    C.stop(a);
    if (m.dx >= n.stand_near) return goToDepth(a);
    m.timer = n.stroll_ticks;
    m.walk = .stand;
    C.faceAndShow(a, .idle);
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
    C.stop(a);
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
    C.stop(a);
    m.timer = n.throw_ticks;
    m.walk = .throw;
    C.faceAndShow(a, .throw);
}

/// The throw (his boomerang leaves his hand at its frame that holds it out: boomerang.zig);
/// then he waits.
fn throwBoomerang(a: Actor) void {
    const m = a.mind;
    m.timer -%= 1;
    if (m.timer != 0) return edgeMove(a);
    m.walk = .wait;
    C.faceAndShow(a, .wait);
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
    C.move(a);
}

/// Once on the screen he walks on a while, then stops across.
fn walkingIn(a: Actor) void {
    const m = a.mind;
    m.walk_in -%= 1;
    if (m.walk_in == 0) {
        m.walk = .decide;
        a.entity.velocity.x = .zero;
    }
    C.move(a);
}

/// He stands, deciding afresh.
fn rest(a: Actor) void {
    const m = a.mind;
    m.walk = .decide;
    m.timer = 0;
    C.faceAndShow(a, .stand);
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
    C.move(a);
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
    C.walkAgain(a);
}

// Blows ----------------------------------------------------------------------------------------

// Holds ----------------------------------------------------------------------------------------

// Thrown ---------------------------------------------------------------------------------------

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
    m.power = C.strength(a).power;
    e.power = m.power;
    m.drawn = @intCast(e.position.x.whole() - w.camera.x.whole());
    C.onBar(a);
    takeUpBoomerangs(a);
    const ago: u8 = @intCast(@min(elapsed, 255));
    switch (m.state) {
        .walk => takeUpWalk(a),
        .swing => a.startMove(.swing),
        .knocked_back => {
            m.attacker = e.struck_by;
            const flying = e.velocity.x.raw != 0 or e.velocity.height.raw != 0 or !C.grounded(a);
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

// The special attack and a player's new life -----------------------------------------------------
