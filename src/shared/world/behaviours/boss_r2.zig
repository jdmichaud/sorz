//! Round 2's boss, with his claws (boss_r2_claws.zig) and the trail his dodges leave
//! (boss_r2_trail.zig). He comes in from the screen's side and sets on a player (the one with its
//! back to him, else as his count says, else the nearer or the farther):
//! - `walk`, one of his ways at a time: off the screen he walks in, across and in depth away from
//!   his target's half; on it he keeps his distance from his target, in a band across, following
//!   its moves in depth the other way; a target whose back is turned he advances on; once his
//!   timer is up, a target low enough he closes in on;
//! - `swing` (the traces' `slash`): near and level with his target, he slashes with his claws, a
//!   blow that knocks down, its frames' blows from its first;
//! - a player's flying kick near and level makes him dodge it: in depth, out of the blows' reach,
//!   his slash's frames running, then across past his target (his trail behind him), until he is
//!   near and level again, where he slashes on;
//! - the rest is the bosses' common body (boss.zig): struck, knocked back or down, held and
//!   thrown, the special attack, a player's new life, beaten and the round won.
//! The status bar shows his health (`World.boss_bar`, `World.bosses`), from his first tick.
//! His numbers, animations and sounds are his definition's (`entities/boss_r2.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const behaviours = @import("../behaviours.zig");
const boss = @import("boss.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Entity = entity.Entity;
const Actor = tick.Actor(@This());
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
    special_still,
};

/// The traces' names of his states that are not theirs.
pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "slash", .state = .swing },
    .{ .name = "thrown6", .state = .tossed },
    .{ .name = "thrown7", .state = .vaulted },
    .{ .name = "thrown8", .state = .flung },
};

/// His way within his state (one byte of the original's for both): walking, he keeps away,
/// closes in, or walks in; slashing, he slashes, dodges in depth, or dashes across.
const keep_away = 0;
const close_in = 1;
const walk_in = 2;
const slashes = 0;
const dodges = 1;
const dashes = 2;

pub const Mind = struct {
    state: State = .appear,
    /// His way within his state (`keep_away`... `dashes`).
    way: u2 = keep_away,
    /// His count, which wraps (a fresh target choice when it is at 0), and his timer to close
    /// in.
    tally: u8 = 0,
    close_timer: u8 = 0,
    /// A player's flying kick he may dodge, at this tick.
    kicking: bool = false,
    /// Out of the blows' reach (dodging, dashing): blows do not land on him.
    invulnerable: bool = false,
    /// The walk in's ticks left once on the screen.
    walk_in: u8 = 0,
    // The body's (boss.zig) -------------------------------------------------------------------
    /// The other states' timer; the bounces left of a fall.
    timer: u8 = 0,
    count: u8 = 0,
    bounces: u8 = 0,
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
    /// His target; whether it may be set on.
    target: ?Handle = null,
    unattackable: bool = false,
    /// From him to the one he measured last: on his left, above him, how far across and in
    /// depth (whole pixels).
    left_of: bool = false,
    above: bool = false,
    dx: u16 = 0,
    dd: u16 = 0,
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

/// `stand` is his walk (his animation 0), `swing` his slash.
pub const Animation = enum { stand, swing, knocked, held, held_behind, flight, bounce, down, lifted };
pub const Move = enum { swing };
pub const Sound = enum { hurt, cry, thud };

pub const Tables = struct {
    /// Carried over a thrower's head, step by step: back from the thrower, then down.
    carried: [10]i8,
};

pub const Numbers = struct {
    // His own ---------------------------------------------------------------------------------
    /// Off the screen (from where he was drawn) he walks in: across toward its middle, in depth
    /// away from his target's half (its depth from `walk_in_low`), a while once on it.
    on_screen_from: i16,
    on_screen_to: i16,
    screen_middle: i16,
    walk_in_speed: Fixed,
    walk_in_low: i16,
    walk_in_ticks: u8,
    walk_in_ticks_second: u8,
    /// The second of twins' speeds: their low word this much more, without its carry.
    second_more: u16,
    /// His count wraps at `count_most`; at `close_after` ticks of his timer a target this low
    /// (`close_level`) he closes in on, until it is above `close_stop_level` or nearer than
    /// `near_least`.
    count_most: u8,
    close_after: u8,
    close_level: i16,
    close_stop_level: i16,
    near_least: u16,
    /// Advancing on a back turned (and closing in), stopping near and level.
    advance_speed: Fixed,
    advance_stop: u16,
    advance_stop_level: u16,
    /// The band across he keeps his distance in (the second of twins'), his speed there; his
    /// speed in depth as his target walks across.
    keep_from: u16,
    keep_to: u16,
    keep_from_second: u16,
    keep_to_second: u16,
    keep_speed: Fixed,
    keep_depth_speed: Fixed,
    /// The slash's reach: at a target going away, still, coming at him; the least; its level,
    /// his target above him or not; its last frame, and his step then.
    slash_reach_going: u16,
    slash_reach_still: u16,
    slash_reach_coming: u16,
    slash_least: u16,
    slash_level_above: u16,
    slash_level: u16,
    slash_ends: u8,
    slash_step: i16,
    /// The dodge: a flying kick this level and near; its speed in depth; this far in depth he
    /// dashes; the dash stops this near (but no nearer) and level; its speed, its aim beside
    /// the target.
    dodge_level: u16,
    dodge_near: u16,
    dodge_speed: Fixed,
    dodge_far: u16,
    dash_stop_far: u16,
    dash_stop_near: u16,
    dash_level_above: u16,
    dash_level: u16,
    dash_speed: Fixed,
    dash_beside: i16,
    /// Of two players: one this near, the other this far, the near one this level, is his
    /// target, his timer to close in set to `target_close`.
    target_near: u16,
    target_far: u16,
    target_level: u16,
    target_close: u8,
    // The body's (boss.zig) -------------------------------------------------------------------
    power: u8,
    hardest_health: u8,
    outside_power: u8,
    struck_from: i16,
    struck_to: i16,
    grab_height: i16,
    keep_far: u16,
    keep_near: u16,
    keep_step_2: u16,
    keep_step_1: u16,
    keep_at: u16,
    steer_fast: Fixed,
    steer: Fixed,
    steer_slow: Fixed,
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
    hold_front: i16,
    hold_behind: i16,
    knee_damage: u8,
    missile_damage: u8,
    thrown_damage: u8,
    last_knee_damage: u8,
    toss_place: i16,
    toss_ticks: u8,
    vault_place: i16,
    vault_ticks: u8,
    fling_place: i16,
    fling_ticks: u8,
    thrown_bounces: u8,
    toss_lift_at: u8,
    toss_up: Fixed,
    toss_lift: i16,
    toss_x: Fixed,
    toss_ahead: i16,
    thrown_gravity: Fixed,
    toss_bounce: Fixed,
    toss_bounce_2: Fixed,
    toss_damage: u8,
    vault_turn_at: u8,
    vault_over_at: u8,
    vault_down_at: u8,
    vault_damage: u8,
    vault_fly_at: u8,
    vault_fly: Fixed,
    vault_slide: Fixed,
    fling_lift_at: u8,
    fling_at: u8,
    fling_up: Fixed,
    fling_x: Fixed,
    fling_turn_at: u8,
    fling_bounce: Fixed,
    fling_bounce_2: Fixed,
    fling_damage: u8,
    special_grounded: u8,
    special_ticks: u16,
    special_ticks_second: u16,
    special_damage: u8,
    blast_x: Fixed,
    blast_up: Fixed,
    dying_x: Fixed,
    blast_ticks: u8,
    blast_bounces: u8,
    depth_most: i16,
};

/// The kinds of his claws and of his trail.
pub const claws_kind = "boss_r2_claws";
pub const trail_kind = "boss_r2_trail";

/// His walk from its start (the body's resets).
pub fn walkAfresh(a: Actor) void {
    a.mind.way = keep_away;
}

// The body's hooks --------------------------------------------------------------------------------

pub const grabbable = C.grabbable;
pub const heldBy = C.heldBy;
pub const letGoBy = C.letGoBy;
pub const takeUpMet = C.takeUpMet;
pub const takeUpHeld = C.takeUpHeld;
pub const specialCalled = C.specialCalled;
pub const knockedBack = C.knockedBack;

/// A blow meets him as it meets the bosses' body (boss.zig), but none lands while he dodges or
/// dashes (the original undoes the striker's hit); grabs still take him.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (a.mind.invulnerable) return false;
    return C.struck(a, blow);
}

// The tick -----------------------------------------------------------------------------------

/// His tick until his blows are met: a special attack or a player's new life may end it; in
/// the body's states his way is his first and he is in reach again; then his state's first part
/// (his target, measured; the damage of a blow met at the last tick, what his holder does to him).
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
    const ended = C.special(a) or C.blast(a);
    switch (m.state) {
        .appear, .walk, .swing => {},
        else => {
            m.way = keep_away;
            m.invulnerable = false;
        },
    }
    if (ended) return C.end(a);
    switch (m.state) {
        .appear => {
            appear(a);
            C.end(a);
        },
        .walk => {
            m.let_go = false;
            const t = chooseTarget(a) orelse return C.end(a);
            m.unattackable = !a.tick.attackable(t);
            C.measure(a, a.other(t).?, true);
            if (C.takeDamage(a) or C.holdTaken(a)) C.end(a);
        },
        .swing => {
            m.let_go = false;
            if (m.target) |t| if (a.other(t)) |o| {
                m.unattackable = !a.tick.attackable(t);
                C.measure(a, o, false);
            };
            if (C.takeDamage(a) or C.holdTaken(a)) C.end(a);
        },
        .held => {
            if (m.holder) |h| if (a.other(h)) |holder| C.measure(a, holder, false);
            if (C.takeDamage(a) or C.holdTaken(a)) C.end(a);
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
        .swing => slash(a),
        .held => C.held(a),
        .knocked_back => C.knockedBackTick(a),
        .down => C.down(a),
        .tossed => C.tossed(a),
        .vaulted => C.vaulted(a),
        .flung => C.flung(a),
        .special_still => C.specialStill(a),
    };
    if (!a.entity.alive()) return;
    // Where he is drawn at the tick's end.
    if (!a.entity.flags.hidden) m.drawn = @intCast(a.entity.position.x.whole() - a.tick.world.camera.x.whole());
}

// Coming in ----------------------------------------------------------------------------------

/// His first tick: shown; the ground he stands on is his; his twin found, the status bar shows
/// him; his target chosen; across a little backward (a speed his first walk replaces); his power
/// and health by the level; he walks.
fn appear(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    e.flags.hidden = false;
    m.ground = e.position.height;
    C.pairUp(a);
    if (C.inFight(a)) C.onBar(a);
    _ = chooseTarget(a);
    e.velocity.x = .pixels(-1);
    const s = C.strength(a);
    m.power = s.power;
    e.power = s.power;
    e.health = s.health;
    m.state = .walk;
    m.way = keep_away;
    e.facing = .right;
    a.animate(.stand);
}

/// Whether the player of `h` kicks flying (a jump kick, armed or not).
fn kicks(a: Actor, h: Handle) bool {
    const p = a.other(h) orelse return false;
    const name = behaviours.stateName(&p.mind) orelse return false;
    return std.mem.eql(u8, name, "jump_kick") or std.mem.eql(u8, name, "armed_jump_kick");
}

/// The one he measures himself against at this tick: his holder while held (his target kept);
/// else his target, chosen afresh (noting a flying kick): the only player in play; of two, one
/// kicking flying (player 1 first); one near and level with the other far (his timer to close
/// in then up); twins each their own player; the one with its back turned to him when the
/// other faces him; both facing him, or neither, his target kept while his count runs, else the
/// farther (player 2 at a tie), or the nearer (player 1 at a tie).
fn chooseTarget(a: Actor) ?Handle {
    const n = a.numbers();
    const m = a.mind;
    m.kicking = false;
    if (m.hold.grabbed) if (m.holder) |h| if (a.other(h) != null) return h;
    const p1 = a.tick.fighting(0);
    const p2 = a.tick.fighting(1);
    const chosen: Handle = pick: {
        if (p1 == null or p2 == null) {
            const only = p1 orelse p2 orelse return null;
            m.kicking = kicks(a, only);
            break :pick only;
        }
        if (kicks(a, p1.?)) {
            m.kicking = true;
            break :pick p1.?;
        }
        if (kicks(a, p2.?)) {
            m.kicking = true;
            break :pick p2.?;
        }
        const first = sizeUp(a, p1.?);
        const second = sizeUp(a, p2.?);
        if (first.across < n.target_near) {
            if (second.across >= n.target_far and first.level < n.target_level) {
                m.close_timer = n.target_close;
                break :pick p1.?;
            }
        } else if (second.across < n.target_far and second.level & 0xFF < n.target_level) {
            m.close_timer = n.target_close;
            break :pick p2.?;
        }
        switch (m.twin) {
            1 => break :pick p1.?,
            2 => break :pick p2.?,
            else => {},
        }
        if (first.faces != second.faces) break :pick if (first.faces) p2.? else p1.?;
        if (m.tally != 0) if (m.target) |t| if (a.other(t) != null) return t;
        if (first.faces) break :pick if (second.across < first.across) p1.? else p2.?;
        break :pick if (second.across >= first.across) p1.? else p2.?;
    };
    m.target = chosen;
    return chosen;
}

/// A player sized up from him: how far across and in depth, and whether it faces him (facing
/// right on his right, or left on his left: dead level across counts as his right).
fn sizeUp(a: Actor, h: Handle) struct { across: u16, level: u16, faces: bool } {
    const p = a.other(h).?;
    const dx = p.position.x.whole() - a.entity.position.x.whole();
    const dd = a.entity.position.depth.whole() - p.position.depth.whole();
    return .{
        .across = @intCast(@min(@abs(dx), std.math.maxInt(u16))),
        .level = @intCast(@min(@abs(dd), std.math.maxInt(u16))),
        .faces = (p.facing == .right) != (dx >= 0),
    };
}

/// `speed` as the second of twins goes: its low word more, without its carry.
fn ofTwin(a: Actor, speed: Fixed) Fixed {
    if (a.mind.twin != 2) return speed;
    return .parts(@intCast(speed.whole()), speed.frac() +% a.numbers().second_more);
}

// Walking ------------------------------------------------------------------------------------

fn walk(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const t = a.other(m.target orelse return) orelse return;
    m.tally +%= 1;
    m.close_timer +%= 1;
    if (!m.unattackable and slashReaches(a, t)) return startSlash(a);
    if (dodge(a)) return;
    if (m.tally >= n.count_most) m.tally = 0;
    switch (m.way) {
        keep_away => keepAway(a, t),
        close_in => closeIn(a, t),
        else => walkingIn(a),
    }
}

/// Whether his slash reaches his target: across, by the way it goes (coming at him, going away,
/// still), but not too near; in depth, level with him; he is not held.
fn slashReaches(a: Actor, t: *const Entity) bool {
    const n = a.numbers();
    const m = a.mind;
    var going = t.velocity.x.whole();
    const reach = if (going == 0) n.slash_reach_still else reach: {
        if (m.left_of) going = -going;
        break :reach if (going < 0) n.slash_reach_coming else n.slash_reach_going;
    };
    if (m.dx >= reach or m.dx < n.slash_least) return false;
    if (m.dd >= (if (m.above) n.slash_level_above else n.slash_level)) return false;
    return !m.hold.grabbed;
}

/// He slashes at his target, his claws out.
fn startSlash(a: Actor) void {
    const m = a.mind;
    m.way = slashes;
    m.close_timer = 0;
    m.state = .swing;
    a.startMove(.swing);
    spawnClaws(a);
}

/// A flying kick near and level (as he walks, closes in, or slashes): he dodges it in depth, out
/// of the blows' reach, his trail behind him and his slash's frames running (held at this tick),
/// his claws out. Returns whether he does.
fn dodge(a: Actor) bool {
    const n = a.numbers();
    const m = a.mind;
    if (!m.kicking or m.dd >= n.dodge_level or m.dx >= n.dodge_near) return false;
    const e = a.entity;
    e.velocity.depth = if (m.above) n.dodge_speed.neg() else n.dodge_speed;
    m.way = dodges;
    m.invulnerable = true;
    spawnTrail(a);
    m.state = .swing;
    spawnClaws(a);
    C.move(a);
    m.tally = 0;
    m.close_timer = 0;
    e.facing = if (m.left_of) .left else .right;
    a.startMove(.swing);
    a.pause(true);
    return true;
}

/// Keeping away: his timer up, he keeps his distance from a target he may not set on, or closes
/// in on one low enough (from his next tick); off the screen he walks in; near, he keeps his
/// distance; on a back turned he advances (but stops near and level), keeping a little above it;
/// else he keeps his distance.
fn keepAway(a: Actor, t: *const Entity) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (m.close_timer >= n.close_after) {
        m.close_timer = 0;
        if (m.unattackable) return keepDistance(a, t);
        if (t.position.depth.whole() >= n.close_level) {
            m.way = close_in;
            return;
        }
    }
    const d = m.drawn;
    if (d < n.on_screen_from or d >= n.on_screen_to) {
        e.velocity.x = if (d >= n.screen_middle) n.walk_in_speed.neg() else n.walk_in_speed;
        const depth = ofTwin(a, n.walk_in_speed);
        e.velocity.depth = if (t.position.depth.whole() >= n.walk_in_low) depth.neg() else depth;
        m.walk_in = if (m.twin == 2) n.walk_in_ticks_second else n.walk_in_ticks;
        m.way = walk_in;
        return C.move(a);
    }
    if (m.dx < n.near_least) return keepDistance(a, t);
    var speed = ofTwin(a, n.advance_speed);
    // Its back turned to him: on his left facing left, on his right facing right.
    if (m.left_of != (t.facing == .left)) return keepDistance(a, t);
    if (m.left_of) speed = speed.neg();
    if (m.dx < n.advance_stop and m.dd < n.advance_stop_level) speed = .zero;
    e.velocity.x = speed;
    e.velocity.depth = C.keepAbove(a);
    C.move(a);
}

/// In his band across from his target: nearer, he backs away; farther, he comes on; within it
/// his speed across is kept. In depth he goes the other way of his target's (up a little as it
/// walks across).
fn keepDistance(a: Actor, t: *const Entity) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const from = if (m.twin == 2) n.keep_from_second else n.keep_from;
    const to = if (m.twin == 2) n.keep_to_second else n.keep_to;
    if (m.dx <= from) {
        e.velocity.x = if (m.left_of) n.keep_speed else n.keep_speed.neg();
    } else if (m.dx >= to) {
        e.velocity.x = if (m.left_of) n.keep_speed.neg() else n.keep_speed;
    }
    e.velocity.depth = if (t.velocity.depth.raw == 0 and @abs(t.velocity.x.whole()) >= 1) n.keep_depth_speed else ofTwin(a, t.velocity.depth.neg());
    C.move(a);
}

/// Closing in, across at speed and a little above his target in depth, until it is above his
/// level or near.
fn closeIn(a: Actor, t: *const Entity) void {
    const n = a.numbers();
    const m = a.mind;
    if (dodge(a)) return;
    if (t.position.depth.whole() < n.close_stop_level or m.dx < n.near_least) m.way = keep_away;
    const speed = ofTwin(a, n.advance_speed);
    a.entity.velocity.x = if (m.left_of) speed.neg() else speed;
    a.entity.velocity.depth = C.keepAbove(a);
    C.move(a);
}

/// Once on the screen he walks on a while, then stops across.
fn walkingIn(a: Actor) void {
    const m = a.mind;
    m.walk_in -%= 1;
    if (m.walk_in == 0) {
        m.way = keep_away;
        a.entity.velocity.x = .zero;
    }
    C.move(a);
}

// The slash ----------------------------------------------------------------------------------

/// His slash and its ways: slashing, a flying kick may make him dodge, and at its last frame he
/// steps the way he faces and walks again; dodging in depth until no kick comes or he is far
/// from his target's depth, then dashing across to beside his target, until near and level,
/// where he slashes on (the slash's frame where it is).
fn slash(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    m.kicking = false;
    switch (m.way) {
        slashes => {
            for (0..2) |k| if (a.tick.fighting(@intCast(k))) |p| {
                if (kicks(a, p)) m.kicking = true;
            };
            if (dodge(a)) return;
            if (a.frame() != n.slash_ends) return;
            e.position.x = e.position.x.add(.pixels(if (e.facing == .left) -@as(i32, n.slash_step) else n.slash_step));
            C.walkAgain(a);
        },
        dodges => {
            m.invulnerable = true;
            if (m.target) |t| m.kicking = kicks(a, t);
            if (!m.kicking or m.dd >= n.dodge_far) m.way = dashes;
            spawnTrail(a);
            C.move(a);
        },
        else => {
            m.invulnerable = true;
            const t = a.other(m.target orelse return) orelse return;
            if (m.dx < n.dash_stop_far and m.dx >= n.dash_stop_near and m.dd < (if (m.above) n.dash_level_above else n.dash_level)) {
                m.way = slashes;
                m.invulnerable = false;
                a.pause(false);
                C.stop(a);
                return;
            }
            const aim = t.position.x.whole() + n.dash_beside - e.position.x.whole();
            e.velocity.x = if (aim < 0) n.dash_speed.neg() else n.dash_speed;
            e.velocity.depth = C.keepAbove(a);
            spawnTrail(a);
            C.move(a);
        },
    }
}

/// His claws, in the first free place after his (none: none), placed at once.
fn spawnClaws(a: Actor) void {
    const kind = a.tick.kinds.find(claws_kind) orelse return;
    const h = a.tick.world.spawnWithin(a.tick.kinds, kind, a.handle.index + 1, 51, a.entity.position, .right) catch return;
    const claws = @import("boss_r2_claws.zig");
    if (a.tick.actor(claws, h)) |c| {
        c.mind.boss = a.handle;
        claws.place(c, a.entity);
    }
}

/// A trail of him where he is, his look at this tick, in the first free place after his.
fn spawnTrail(a: Actor) void {
    const kind = a.tick.kinds.find(trail_kind) orelse return;
    const h = a.tick.world.spawnWithin(a.tick.kinds, kind, a.handle.index + 1, 51, a.entity.position, a.entity.facing) catch return;
    const trail = @import("boss_r2_trail.zig");
    if (a.tick.actor(trail, h)) |t| trail.copy(t, a.entity, a.mind.twin != 0, a.tick.fighting(0) != null and a.tick.fighting(1) != null);
}

// Taken up from a situation ------------------------------------------------------------------

/// Taken up from a situation another program recorded, `elapsed` ticks into his state: his
/// ground (the round's), his power, the status bar; drawn where he is; his state's timers gone
/// down by then.
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
    const ago: u8 = @intCast(@min(elapsed, 255));
    switch (m.state) {
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
