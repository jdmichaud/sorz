//! Round 3's boss, with his part (boss_r3_part.zig: what his frames leave out of him, placed by
//! him) and, for two players, the helper that watches a pair of them (boss_r3_helper.zig). His
//! code is his own, not the bosses' common body (boss.zig); his states, as the traces name them:
//! - `appear`: his first tick: his part made, the other of a pair found (and the helper made by
//!   the one with a bar of its own), his health and power by the level, the status bar shows
//!   him; he walks;
//! - `approach`: he walks toward his target, along the ways it is far, until it is level in depth
//!   (`approach_level`); then `size_up`: a few ticks, then he charges (`charge`) or, at a middling
//!   distance in the screen's middle, backs off (`back_off`) a while and sizes it up again;
//! - `charge`: fast across at his target's depth until near (`charge_near`) or at the screen's
//!   edge; near, a slam (his blow knocks down; a player he meets in his charge is knocked down);
//! - `hug`: a player his walk meets is caught and hugged, its stages moving it;
//! - a player's blow strikes him (`struck`, then `staggered`), or knocks him away
//!   (`knocked_away`: he flies, bounces, lies, gets up: `get_up`); a thing thrown knocks him
//!   away, the pepper strikes him three times (`hit_by_weapon`);
//! - `held` by a player: placed in front of it, he takes its knees (the last knocks him away),
//!   is thrown (`thrown`), thrown over (`thrown_over`) and slammed (`slammed`); the hold breaks
//!   after a while;
//! - `knocked_out`: his health gone, the fight is over: the section's enemies knocked down, he
//!   rises, sits, drops, his points, he blinks out, and the round is won; one whose beating is
//!   not the round's end (`goes_as_enemy`: round 5's, a variant, which blinks out at once) goes
//!   as an enemy, counted off as a boss (script.zig's `bossCountedOff`).
//! A player's new life knocks him away; the special attack holds him still and costs him health
//! at its end. His numbers, animations and sounds are his definition's (`entities/boss_r3.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const behaviours = @import("../behaviours.zig");
const script = @import("../script.zig");
const systems = @import("../systems.zig");
const world_mod = @import("../world.zig");
const part_mod = @import("boss_r3_part.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Entity = entity.Entity;
const Actor = tick.Actor(@This());

/// His states, in the original's order (the grab's table names them by number).
pub const State = enum {
    appear,
    approach,
    size_up,
    back_off,
    struck,
    staggered,
    knocked_away,
    charge,
    hug,
    slammed,
    get_up,
    held,
    knocked_out,
    thrown_over,
    thrown,
    hit_by_weapon,
};

/// What met him at this tick (the original's hit test finds one): a player's blow, a player's
/// grab, a thing thrown.
pub const Hit = union(enum) {
    none,
    blow: struct { by: Handle, damage: i16, knocks_down: bool },
    grab: Handle,
    missile: struct { by: Handle, damage: i16, pepper: bool },
};

pub const Mind = struct {
    state: State = .appear,
    /// The step within his state, and its ticks.
    step: u8 = 0,
    ticks: u16 = 0,
    /// His part, the other of a pair, his target, and the one who struck or holds him.
    part: ?Handle = null,
    other: ?Handle = null,
    target: ?Handle = null,
    hitter: ?Handle = null,
    /// A way (1 or -1: a throw's, a hug's) or a shake in height; a count (the pepper's strikes).
    dir: i16 = 0,
    count: u8 = 0,
    /// The hug's stage, or the holder's frame seen last.
    stage: u8 = 0,
    /// A shake's step across; the change of his speed across, and in height, a tick.
    shake: i16 = 0,
    accel: Fixed = .zero,
    gravity: Fixed = .zero,
    /// His charge started outside the screen's middle.
    outside: bool = false,
    /// The blow met knocks him away; the one holding him let go.
    knocks_down: bool = false,
    let_go: bool = false,
    /// The special attack is under way; it knocked him out (player 2's).
    special_seen: bool = false,
    special_ko: bool = false,
    special_p2: bool = false,
    /// Done with his knockout (the helper clears him).
    done: bool = false,
    /// A player's new life came: he is knocked away.
    entered: bool = false,
    /// His power; where he was drawn across (from the camera) at the last tick.
    power: u8 = 0,
    drawn: i16 = 0,
    /// This tick: what met him, whether his state looks for it, whether his tick ended early.
    hit: Hit = .none,
    looks: bool = false,
    ended: bool = false,
};

pub const Animation = enum { walk, charge, slam, hug, struck, knocked, thrown_over, get_up, thrown };
pub const Sound = enum { hurt, thud, cry };

pub const Numbers = struct {
    variant_power: u8,
    variant_health: u8,
    walk_speed: Fixed,
    /// Approaching: his target this far in depth or more, he walks on; sizing it up, across.
    approach_level: i16,
    approach_near: i16,
    variant_level: i16,
    size_up_ticks: u16,
    /// Sized up: from `back_off_near` (excluded) to `back_off_far` across, in the screen's
    /// middle, he backs off.
    back_off_far: i16,
    back_off_near: i16,
    back_off_ticks: u16,
    struck_ticks: u16,
    shake: i16,
    weapon_hits: u8,
    weapon_ticks: u16,
    knock_away_x: Fixed,
    knock_away_up: Fixed,
    knock_away_slowing: Fixed,
    knocked_gravity: Fixed,
    falling_gravity: Fixed,
    bounce_above: Fixed,
    bounce_shift: u5,
    lie_ticks: u16,
    knocked_lie_ticks: u16,
    get_up_ticks: u16,
    charge_speed: Fixed,
    charge_near: i16,
    /// The screen's edges a charge stops at, where he was drawn across.
    charge_right: i16,
    charge_left: i16,
    slam_wait: u16,
    slam_ticks: u16,
    held_ahead: i16,
    held_ticks: u16,
    thrown_over_ticks: u16,
    thrown_up: Fixed,
    thrown_gravity: Fixed,
    thrown_x: Fixed,
    thrown_slowing: Fixed,
    thrown_over: i16,
    thrown_down: Fixed,
    thrown_bounce: Fixed,
    thrown_damage: i16,
    thrown_slide: u16,
    slammed_ticks: u16,
    slammed_up: Fixed,
    slammed_gravity: Fixed,
    slammed_x: Fixed,
    slammed_slowing: Fixed,
    slammed_damage: i16,
    special_damage: i16,
    knocked_out_rise: u16,
    knocked_out_drop: u16,
    knocked_out_shake: i16,
    blink_ticks: u16,
    blink_from: u16,
    blink_hidden: u16,
    points: u32,
};

pub const Tables = struct {
    /// His health and power by the options' level.
    strength: [8]u8,
    /// His part's places from him (across, in height) by an index: standing, charging, getting
    /// up.
    part_offsets: [6]i16,
    /// The state a player's grab sends him to, by the holder's request (its state's: `request`);
    /// negative: none.
    grab_states: [12]i8,
    /// By the holder's character, the one thrown's places from it by the holder's frame: rows of
    /// 4 (thrown over, slammed, thrown), across then in height.
    throw_x_axel: [12]i16,
    throw_height_axel: [12]i16,
    throw_x_adam: [12]i16,
    throw_height_adam: [12]i16,
    throw_x_blaze: [12]i16,
    throw_height_blaze: [12]i16,
    /// The hug's stages: their ticks, the one hugged moved across (against his side) and in
    /// height.
    hug_ticks: [4]u8,
    hug_x: [4]i16,
    hug_height: [4]i16,
};

pub const part_kind = "boss_r3_part";

/// His entry in the status bar's names and bars (the next one for the second of a pair).
const bar_entry = 6;
pub const helper_kind = "boss_r3_helper";

/// The kind a thing thrown must be to strike him as the pepper does (three times, shaken).
const pepper_kind = "pepper";

// The hooks --------------------------------------------------------------------------------------

/// A player's new life knocks him away at his next turn.
pub fn knockedBack(a: Actor) void {
    a.mind.entered = true;
}

/// The special attack: he notes it at his turn (`begin`).
pub fn specialCalled(a: Actor) void {
    _ = a;
}

/// A blow meets him only in a state that looks for blows at this tick, the first of the tick: a
/// player's while he was drawn in the screen's middle; a thing thrown: the pepper strikes him,
/// another's damage (a weapon's own, a body's 1) knocks him away.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    const m = a.mind;
    if (!m.looks or m.hit != .none) return false;
    if (blow.missile) {
        const thing = a.other(blow.attacker) orelse return false;
        const k = a.tick.kindOf(thing);
        const by = if (thing.missile) |mi| mi.by else blow.attacker;
        m.hit = .{ .missile = .{
            .by = by,
            .damage = if (k.family() == .weapon) blow.damage else 1,
            .pepper = std.mem.eql(u8, k.definition.name, pepper_kind),
        } };
        return true;
    }
    if (m.drawn < -8 or m.drawn >= 328) return false;
    m.hit = .{ .blow = .{ .by = blow.attacker, .damage = blow.damage, .knocks_down = blow.reaction == .knock_down } };
    return true;
}

/// A player's grab takes him in a state that looks at this tick, within his height, when the
/// grab's table sends him somewhere for the holder's request.
pub fn grabbable(a: Actor, by: Handle) bool {
    const m = a.mind;
    if (!m.looks or m.hit != .none) return false;
    const holder = a.other(by) orelse return false;
    if (@abs(holder.position.height.whole() - a.entity.position.height.whole()) > 8) return false;
    if (a.tables().grab_states[request(a, holder)] < 0) return false;
    m.hit = .{ .grab = by };
    return true;
}

pub fn heldBy(a: Actor, holder: Handle) void {
    a.mind.hitter = holder;
    a.mind.let_go = false;
}

/// His holder let him go: he breaks free at his turn.
pub fn letGoBy(a: Actor, holder: Handle) void {
    _ = holder;
    a.mind.let_go = true;
}

/// What a player holding him asks of him by its state (the original's request, its $7D): 1
/// holding him in front, 2 from behind, 3 a knee, 4 the last knee, 5 and 7 a throw over the
/// shoulder, 6 a vault over him, 9 a throw back, 10 an escape; 0 none.
fn request(a: Actor, holder: *const Entity) u8 {
    _ = a;
    const name = behaviours.stateName(&holder.mind) orelse return 0;
    const table = [_]struct { []const u8, u8 }{
        .{ "grab", 1 },
        .{ "grab_behind", 2 },
        .{ "knee", 3 },
        .{ "knee_last", 4 },
        .{ "grab_blow", 5 },
        .{ "vault", 6 },
        .{ "vault_land", 6 },
        .{ "throw", 9 },
        .{ "throw_back", 9 },
        .{ "escape", 10 },
    };
    for (table) |r| if (std.mem.eql(u8, r[0], name)) return r[1];
    return 0;
}

// The tick ---------------------------------------------------------------------------------------

/// His tick until the blows are met: with no player fighting he stands still; a player's new
/// life knocks him away; the special attack holds him (its end costs him health and knocks him
/// away); then whether his state looks for blows and grabs at this tick.
pub fn begin(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const w = a.tick.world;
    e.flags.still = true;
    m.hit = .none;
    m.looks = false;
    m.ended = false;
    if (!anyFighting(a)) {
        a.pause(true);
        if (partOf(a)) |p| p.animation.paused = true;
        m.ended = true;
        return;
    }
    if (m.entered) {
        m.entered = false;
        if (e.health > 0 and m.state != .knocked_away and m.state != .held) {
            setState(a, .knocked_away);
            knockAway(a);
            afterSpecial(a);
        }
    } else if (w.special) {
        m.special_seen = true;
        m.ended = true;
        return;
    } else if (m.special_seen) {
        m.special_seen = false;
        e.health -= n.special_damage;
        a.tick.out.hits.append(.{ .attacker = null, .target = a.handle, .damage = n.special_damage });
        if (e.health <= 0) {
            m.special_ko = true;
            if (w.special_by) |by| if (w.players[1].entity) |p2| {
                m.special_p2 = p2.eql(by);
            };
        }
        afterSpecial(a);
    }
    m.looks = switch (m.state) {
        .approach, .back_off => m.step != 0,
        .size_up => true,
        .charge => m.step == 1 or m.step == 3,
        .hit_by_weapon => m.step == 2 or m.step == 3,
        else => false,
    };
}

/// His tick after the blows were met: his state's.
pub fn think(a: Actor) void {
    const m = a.mind;
    if (!m.ended) switch (m.state) {
        .appear => appear(a),
        .approach => approach(a),
        .size_up => sizeUp(a),
        .back_off => backOff(a),
        .struck => struck_(a),
        .staggered => staggered(a),
        .knocked_away => knockedAway(a),
        .charge => charge(a),
        .hug => hug(a),
        .slammed => slammed(a),
        .get_up => getUp(a),
        .held => held(a),
        .knocked_out => knockedOut(a),
        .thrown_over => thrownOver(a),
        .thrown => thrown(a),
        .hit_by_weapon => hitByWeapon(a),
    };
    if (!a.entity.alive()) return;
    m.drawn = @intCast(a.entity.position.x.whole() - a.tick.world.camera.x.whole());
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

/// A hug under way lets its player go; past his first state he is knocked away.
fn afterSpecial(a: Actor) void {
    if (a.mind.state == .hug) releaseHugged(a);
    if (a.mind.state == .appear) return;
    setState(a, .knocked_away);
    knockAway(a);
}

// His part, his moves -----------------------------------------------------------------------------

fn partOf(a: Actor) ?*Entity {
    return a.other(a.mind.part orelse return null);
}

fn partActor(a: Actor) ?tick.Actor(part_mod) {
    return a.tick.actor(part_mod, a.mind.part orelse return null);
}

/// His part at his place, offset by entry `index` of his part's places.
fn placePart(a: Actor, index: usize) void {
    const p = partOf(a) orelse return;
    const t = a.tables();
    p.position = a.entity.position;
    p.position.x = p.position.x.add(.pixels(t.part_offsets[2 * index]));
    p.position.height = p.position.height.add(.pixels(t.part_offsets[2 * index + 1]));
}

fn move(a: Actor) void {
    const e = a.entity;
    e.position = e.position.add(e.velocity);
}

fn target(a: Actor) ?*Entity {
    return a.other(a.mind.target orelse return null);
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
    const t = target(a) orelse return .{ .x = 1, .depth = 1 };
    const e = a.entity;
    return .{
        .x = if (t.position.x.lessThan(e.position.x)) -1 else 1,
        .depth = if (t.position.depth.lessThan(e.position.depth)) -1 else 1,
    };
}

/// How far his target is (whole pixels), in depth and across, and whether at least the limits.
const Reach = struct { far_depth: bool, far_x: bool, depth: i32, x: i32 };

fn reach(a: Actor, level: i16, near: i16) Reach {
    const t = target(a) orelse return .{ .far_depth = false, .far_x = false, .depth = 0, .x = 0 };
    const e = a.entity;
    const dd: i32 = @intCast(@abs(t.position.depth.whole() - e.position.depth.whole()));
    const dx: i32 = @intCast(@abs(t.position.x.whole() - e.position.x.whole()));
    return .{ .far_depth = dd >= level, .far_x = dx >= near, .depth = dd, .x = dx };
}

/// He and his part face the way he moves across.
fn faceBySpeed(a: Actor) void {
    setFacing(a, a.entity.velocity.x.raw < 0);
}

/// He and his part face his target.
fn faceTarget(a: Actor) void {
    setFacing(a, direction(a).x < 0);
}

fn setFacing(a: Actor, left: bool) void {
    a.entity.facing = if (left) .left else .right;
    if (partActor(a)) |p| part_mod.face(p, left);
}

/// His speeds turned toward his target (his facing by his speed when it turns across).
fn aim(a: Actor) void {
    const d = direction(a);
    const v = &a.entity.velocity;
    if ((v.x.raw < 0) != (d.x < 0)) {
        v.x = v.x.neg();
        faceBySpeed(a);
    }
    if ((v.depth.raw < 0) != (d.depth < 0)) v.depth = v.depth.neg();
}

/// Animation `which` from its start, facing by his speed.
fn animate(a: Actor, which: Animation) void {
    a.animate(which);
    faceBySpeed(a);
}

/// He walks, his part shown and walking with him at its place.
fn standUp(a: Actor) void {
    animate(a, .walk);
    if (partActor(a)) |p| part_mod.stand(p);
    placePart(a, 0);
}

/// He walks toward his target.
fn walkAgain(a: Actor) void {
    const n = a.numbers();
    standUp(a);
    a.entity.velocity.depth = n.walk_speed;
    a.entity.velocity.x = n.walk_speed;
    aim(a);
}

fn still(a: Actor) void {
    a.pause(true);
    if (partOf(a)) |p| p.animation.paused = true;
}

fn animated(a: Actor) void {
    a.pause(false);
    if (partOf(a)) |p| p.animation.paused = false;
}

fn hidePart(a: Actor) void {
    if (partOf(a)) |p| p.flags.hidden = true;
}

/// A shake across: his step, then the other way.
fn shakeStep(a: Actor) void {
    const m = a.mind;
    a.entity.position.x = a.entity.position.x.add(.pixels(m.shake));
    m.shake = -m.shake;
}

/// Knocked away from his target: up and away from the way it faces, slowing.
fn knockAway(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    a.mind.accel = n.knock_away_slowing;
    e.velocity.height = n.knock_away_up;
    e.velocity.x = n.knock_away_x;
    if (target(a)) |t| if (t.facingLeft()) {
        e.velocity.x = e.velocity.x.neg();
        a.mind.accel = a.mind.accel.neg();
    };
}

/// Damage `damage` from `by`; his health gone, he is knocked away.
fn hurt(a: Actor, by: ?Handle, damage: i16) void {
    a.tick.takeDamage(a.handle, by, damage);
    if (a.entity.health > 0) return;
    setState(a, .knocked_away);
    knockAway(a);
}

// What meets him ----------------------------------------------------------------------------------

/// The hit test of a state that looks: what met him at this tick (a player hitting him becomes
/// his target), else his blow on a player. Returns whether he was met (his state's tick ends;
/// not for his blow in his back off).
fn hitCheck(a: Actor) bool {
    const m = a.mind;
    switch (m.hit) {
        .none => return blowOnPlayers(a),
        .blow => |b| {
            if (a.tick.isPlayer(b.by)) m.target = b.by;
            m.hitter = b.by;
            a.sound(.hurt);
            m.state = .struck;
            if (b.knocks_down) {
                setState(a, .knocked_away);
                knockAway(a);
            }
            hurt(a, b.by, b.damage);
        },
        .grab => |g| {
            m.target = g;
            m.hitter = g;
            const holder = a.other(g) orelse return true;
            const s = a.tables().grab_states[request(a, holder)];
            if (s >= 0) setState(a, @fromBackingInt(@intCast(s)));
        },
        .missile => |t| {
            if (a.tick.isPlayer(t.by)) m.target = t.by;
            m.hitter = t.by;
            a.sound(.hurt);
            m.step = 0;
            if (t.pepper) {
                m.state = .hit_by_weapon;
                return true;
            }
            a.tick.takeDamage(a.handle, t.by, t.damage);
            m.state = .knocked_away;
            knockAway(a);
        },
    }
    return true;
}

/// His frame's blow meets a player's body (player 1's first; not one struck at this tick): in
/// his charge it knocks the player down; backing off, nothing; held, nothing more; else he
/// catches the player in a hug.
fn blowOnPlayers(a: Actor) bool {
    const m = a.mind;
    const e = a.entity;
    const attack = e.boxes.attack orelse return false;
    const k = a.kind.definition;
    for (a.tick.world.players) |p| {
        const ph = p.entity orelse continue;
        const pe = a.other(ph) orelse continue;
        if (pe.mind != .player or !a.tick.catchable(ph)) continue;
        const body = pe.boxes.body orelse continue;
        if (!systems.meet(e, &k.boxes[attack], pe, &a.tick.kindOf(pe).definition.boxes[body])) continue;
        m.target = ph;
        switch (m.state) {
            .back_off => return false,
            .held => return true,
            .charge => _ = a.tick.struck(ph, .{ .attacker = a.handle, .damage = m.power, .reaction = .knock_down, .push = .zero }),
            else => {
                m.let_go = false;
                setState(a, .hug);
                a.tick.catchHeld(a.handle, ph, false);
            },
        }
        return true;
    }
    return false;
}

// Coming in ----------------------------------------------------------------------------------------

/// His first tick: his part made in the first free enemy place; the other of a pair found; the
/// helper made by the one with a bar of its own (not a variant); his health and power by the
/// level; the status bar shows him; his target; he walks.
fn appear(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const w = a.tick.world;
    const t = a.tables();
    e.flags.hidden = false;
    e.flags.stays = true;
    const places = world_mod.World.enemy_places;
    if (a.tick.kinds.find(part_kind)) |pk| {
        if (w.spawnWithin(a.tick.kinds, pk, places.from, places.to, e.position, .right)) |ph| {
            m.part = ph;
            const p = w.get(ph).?;
            p.flags.stays = true;
            p.flags.shadowless = true;
            p.flags.in_front = e.flags.in_front;
            if (a.tick.actor(part_mod, ph)) |pa| pa.mind.boss = a.handle;
        } else |_| {}
    }
    m.other = otherBoss(a);
    const bar = e.spawn.bar orelse 0;
    if (bar != 0 and !e.spawn.traits.twin) {
        if (a.tick.kinds.find(helper_kind)) |hk| {
            if (w.spawnWithin(a.tick.kinds, hk, places.from, places.to, e.position, .right)) |hh| {
                if (a.tick.actor(@import("boss_r3_helper.zig"), hh)) |ha| ha.mind.owner = a.handle;
            } else |_| {}
        }
    }
    // His health and power by the level (a variant more power, and more health with its
    // palette's).
    const level: usize = if (a.tick.plan) |p| p.level else 1;
    e.health = t.strength[2 * level];
    m.power = t.strength[2 * level + 1];
    if (e.spawn.traits.twin) {
        m.power += n.variant_power;
    } else {
        // The status bar: his entry by his bar of his own.
        w.boss_bar = if (bar == 0) bar_entry else bar_entry + 1;
        w.bosses[if (bar == 0) 0 else 1] = a.handle;
    }
    e.power = m.power;
    setState(a, .approach);
    chooseTarget(a);
    walkAgain(a);
}

/// The first other boss of his kind among the enemies.
fn otherBoss(a: Actor) ?Handle {
    const w = a.tick.world;
    const places = world_mod.World.enemy_places;
    for (places.from..places.to) |i| {
        if (i == a.handle.index) continue;
        const o = &w.entities[i];
        if (!o.alive() or o.kind == null or o.kind.? != a.entity.kind.?) continue;
        return w.handleAt(i);
    }
    return null;
}

// Approaching, sizing up, backing off, struck ----------------------------------------------------

fn approach(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (m.step == 0) {
        animated(a);
        m.step = 1;
        walkAgain(a);
        return faceTarget(a);
    }
    if (hitCheck(a)) return;
    aim(a);
    const r = reach(a, n.approach_level, n.approach_near);
    if (r.far_depth) {
        if (r.far_depth) a.entity.position.depth = a.entity.position.depth.add(a.entity.velocity.depth);
        if (r.far_x) a.entity.position.x = a.entity.position.x.add(a.entity.velocity.x);
        return placePart(a, 0);
    }
    still(a);
    m.ticks = n.size_up_ticks;
    m.state = .size_up;
}

fn sizeUp(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (hitCheck(a)) return;
    m.ticks -%= 1;
    if (m.ticks != 0) return aim(a);
    if (a.entity.spawn.traits.twin) {
        const r = reach(a, n.variant_level, n.approach_near);
        return setState(a, if (r.far_depth) .approach else .charge);
    }
    const r = reach(a, n.approach_level, n.approach_near);
    if (r.far_depth) return setState(a, .approach);
    if (r.x <= n.back_off_far and r.x > n.back_off_near and inMiddle(a)) return setState(a, .back_off);
    setState(a, .charge);
}

/// Whether he was drawn on the screen at the last tick.
fn inMiddle(a: Actor) bool {
    return a.mind.drawn >= 0 and a.mind.drawn < 320;
}

fn backOff(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (m.step == 0) {
        animated(a);
        walkAgain(a);
        faceTarget(a);
        e.velocity.x = e.velocity.x.neg();
        e.velocity.depth = .zero;
        m.step = 1;
        m.ticks = n.back_off_ticks;
        return;
    }
    if (hitCheck(a)) return;
    if (inMiddle(a)) {
        m.ticks -%= 1;
        if (m.ticks != 0) {
            move(a);
            return placePart(a, 0);
        }
    }
    still(a);
    chooseTarget(a);
    m.ticks = n.size_up_ticks;
    setState(a, .size_up);
}

fn struck_(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.ticks = n.struck_ticks;
    m.shake = n.shake;
    animate(a, .struck);
    faceTarget(a);
    m.state = .staggered;
    hidePart(a);
}

fn staggered(a: Actor) void {
    const m = a.mind;
    m.ticks -%= 1;
    if (m.ticks == 0) return setState(a, .back_off);
    shakeStep(a);
}

/// Struck by the pepper: three times struck and up again, the hits looked at; then he sizes up
/// his target.
fn hitByWeapon(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    switch (m.step) {
        0, 1 => {
            if (m.step == 0) m.count = n.weapon_hits;
            m.ticks = n.weapon_ticks;
            animate(a, .struck);
            faceTarget(a);
            m.step = 2;
            hidePart(a);
        },
        2 => {
            m.ticks -%= 1;
            if (m.ticks == 0) {
                m.ticks = n.weapon_ticks;
                m.step = 3;
                walkAgain(a);
                still(a);
            }
            _ = hitCheck(a);
        },
        else => {
            m.ticks -%= 1;
            if (m.ticks == 0) {
                m.count -%= 1;
                if (@as(i8, @bitCast(m.count)) <= 0) {
                    chooseTarget(a);
                    walkAgain(a);
                    aim(a);
                    m.ticks = 1;
                    return setState(a, .size_up);
                }
                m.step = 1;
            }
            _ = hitCheck(a);
        },
    }
}

// Knocked away, falling, up again --------------------------------------------------------------

fn knockedAway(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    switch (m.step) {
        0 => {
            if (a.entity.health <= 0) a.sound(.cry);
            a.pause(true);
            animate(a, .knocked);
            a.pause(true);
            m.gravity = n.knocked_gravity;
            a.entity.velocity.depth = .zero;
            m.step = 1;
            if (partOf(a)) |p| {
                p.flags.hidden = true;
                p.animation.paused = true;
                p.animation.frame = 0;
            }
        },
        1 => rise(a),
        2 => {
            fall(a);
            if (m.step == 2) return;
            m.ticks = n.knocked_lie_ticks;
            m.step = 3;
            a.entity.velocity.height = .zero;
        },
        else => {
            lie(a);
            if (m.state == .get_up and a.entity.health <= 0) knockout(a);
        },
    }
}

/// Rising: his speeds change (across by his slowing, in height by his gravity) and he moves;
/// once falling, his next frame, a lighter gravity.
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

/// Falling to the ground: there, the thud and a bounce at an eighth of the speed while it is
/// fast, else he lies (`lie_ticks`, the next step).
fn fall(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const ground = a.tick.world.ground;
    if (e.position.height.whole() < ground.whole()) {
        e.velocity.x = e.velocity.x.add(m.accel);
        e.velocity.height = e.velocity.height.add(m.gravity);
        return move(a);
    }
    e.position.height = .pixels(ground.whole());
    a.sound(.thud);
    if (n.bounce_above.lessThan(e.velocity.height)) {
        e.velocity.height = e.velocity.height.neg().shr(n.bounce_shift);
        return move(a);
    }
    e.velocity.height = .zero;
    m.ticks = n.lie_ticks;
    m.step = 3;
}

/// Lying for his ticks, then up again.
fn lie(a: Actor) void {
    const m = a.mind;
    m.ticks -%= 1;
    if (m.ticks != 0) return;
    setState(a, .get_up);
}

/// His health gone: knocked out; one alone (not a variant) with no helper ends the section's
/// fight; with a helper, the helper is told.
fn knockout(a: Actor) void {
    const m = a.mind;
    m.state = .knocked_out;
    if (a.entity.spawn.traits.twin) return;
    if (helperOf(a)) |h| {
        const bar = a.entity.spawn.bar orelse 0;
        if (bar != 0) h.mind.beaten.second = true else h.mind.beaten.first = true;
        return;
    }
    a.tick.bossBeaten();
}

fn helperOf(a: Actor) ?tick.Actor(@import("boss_r3_helper.zig")) {
    const w = a.tick.world;
    const k = a.tick.kinds.find(helper_kind) orelse return null;
    const places = world_mod.World.enemy_places;
    for (places.from..places.to) |i| {
        const o = &w.entities[i];
        if (!o.alive() or o.kind == null or o.kind.? != k) continue;
        return a.tick.actor(@import("boss_r3_helper.zig"), w.handleAt(i).?);
    }
    return null;
}

fn getUp(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (m.step != 0) {
        m.ticks -%= 1;
        if (m.ticks == 0) setState(a, .approach);
        return;
    }
    animate(a, .get_up);
    m.ticks = n.get_up_ticks;
    m.step = 1;
    partUp(a);
    aim(a);
    faceTarget(a);
    placePart(a, 2);
}

/// His part shown, standing (its own side kept).
fn partUp(a: Actor) void {
    const p = partActor(a) orelse return;
    part_mod.show(p);
}

// The charge ---------------------------------------------------------------------------------------

fn charge(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    switch (m.step) {
        0 => {
            a.pause(false);
            animate(a, .charge);
            e.velocity.depth = .zero;
            e.velocity.x = n.charge_speed;
            aim(a);
            m.step = 1;
            m.outside = !inMiddle(a);
            if (partActor(a)) |p| part_mod.charge(p, e.velocity.x.raw >= 0);
        },
        1 => {
            if (hitCheck(a)) return;
            const r = reach(a, 0, n.charge_near);
            if (r.far_x) {
                move(a);
                placePart(a, 1);
                if (e.velocity.x.raw >= 0) {
                    if (m.drawn < n.charge_right) return;
                } else if (m.drawn > n.charge_left) return;
                walkAgain(a);
                aim(a);
                m.ticks = 1;
                return setState(a, .size_up);
            }
            a.pause(true);
            a.setFrame(0);
            a.setTicksLeft(1);
            m.ticks = n.slam_wait;
            m.step = 2;
            if (partActor(a)) |p| part_mod.slam(p);
        },
        2 => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            m.ticks = n.slam_ticks;
            animate(a, .slam);
            m.step = 3;
            hidePart(a);
        },
        else => {
            m.ticks -%= 1;
            if (m.ticks == 0) {
                m.let_go = false;
                setState(a, .back_off);
            }
            _ = hitCheck(a);
        },
    }
}

// The hug ------------------------------------------------------------------------------------------

/// The player caught, hugged by stages, each moving it; out of his hold (let go, freed) the hug
/// ends at its last frame; then he backs off.
fn hug(a: Actor) void {
    const m = a.mind;
    const t = a.tables();
    const ph = m.target orelse return hugEnd(a);
    const pe = a.other(ph) orelse return hugEnd(a);
    if (pe.holder == null or !pe.holder.?.eql(a.handle)) {
        a.setFrame(3);
        return hugEnd(a);
    }
    switch (m.step) {
        0 => {
            m.dir = @intCast(direction(a).x);
            animate(a, .hug);
            faceTarget(a);
            a.pause(true);
            m.stage = 0;
            m.step = 1;
            if (partActor(a)) |p| part_mod.hug(p, m.dir >= 0);
            pe.position = a.entity.position;
            pe.position.depth = pe.position.depth.add(.pixels(1));
            hugStage(a, pe);
            placePart(a, 1);
        },
        else => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            m.stage += 1;
            a.setFrame(a.frame() + 1);
            switch (m.stage) {
                2 => if (partOf(a)) |p| {
                    p.flags.hidden = false;
                },
                3 => if (partActor(a)) |p| part_mod.nextFrame(p),
                else => {
                    a.setFrame(3);
                    releaseHugged(a);
                    return hugEnd(a);
                },
            }
            _ = t;
            hugStage(a, pe);
        },
    }
}

/// The hug's stage: its ticks; the one hugged moved across (against his side) and in height.
fn hugStage(a: Actor, pe: *Entity) void {
    const m = a.mind;
    const t = a.tables();
    const s = m.stage;
    m.ticks = t.hug_ticks[s];
    var dx: i32 = t.hug_x[s];
    if (m.dir >= 0) dx = -dx;
    pe.position.x = pe.position.x.add(.pixels(dx));
    pe.position.height = pe.position.height.add(.pixels(t.hug_height[s]));
}

/// The hug lets its player go, knocked down with his power's damage.
fn releaseHugged(a: Actor) void {
    const m = a.mind;
    const ph = m.target orelse return;
    const pe = a.other(ph) orelse return;
    if (pe.holder == null or !pe.holder.?.eql(a.handle)) return;
    a.letGo();
    _ = a.tick.struck(ph, .{ .attacker = a.handle, .damage = m.power, .reaction = .knock_down, .push = .zero });
}

fn hugEnd(a: Actor) void {
    a.mind.let_go = false;
    setState(a, .back_off);
}

// Held, thrown --------------------------------------------------------------------------------------

/// Held by a player: in front of it, on the ground, a while of its requests: let go, he backs
/// off; a knee strikes him (shaken a while); the last knee knocks him away a moment later; a
/// throw sends him flying, a vault over him throws him over; a throw back gives the hold more
/// time. The time out, the hold breaks, but in a throw back: then his blow on the player hugs it.
fn held(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    switch (m.step) {
        0 => {
            walkAgain(a);
            still(a);
            const hh = m.hitter orelse return breakHold(a);
            const holder = a.other(hh) orelse return breakHold(a);
            e.position = holder.position;
            var ahead: i32 = n.held_ahead;
            e.facing = .left;
            if (holder.facingLeft()) {
                e.facing = .right;
                ahead = -ahead;
            }
            e.position.x = e.position.x.add(.pixels(ahead));
            e.position.height = .pixels(a.tick.world.ground.whole());
            faceTarget(a);
            m.ticks = n.held_ticks;
            m.step = 1;
            placePart(a, 0);
        },
        1 => {
            if (m.let_go) {
                m.let_go = false;
                return setState(a, .back_off);
            }
            m.ticks -%= 1;
            if (m.ticks != 0) return reaction(a);
            const hh = m.hitter orelse return breakHold(a);
            const holder = a.other(hh) orelse return breakHold(a);
            if (request(a, holder) != 9) return breakHold(a);
            if (!blowOnPlayers(a)) return breakHold(a);
            if (m.state == .held) {
                a.letGo();
                setState(a, .hug);
            }
        },
        2 => {
            a.sound(.hurt);
            m.ticks = n.struck_ticks;
            m.shake = n.shake;
            animate(a, .struck);
            m.step = 3;
            hidePart(a);
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
            const hh = m.hitter;
            const holder = if (hh) |h| a.other(h) else null;
            const power: i16 = if (holder) |h| holderPower(a, h) else 0;
            a.tick.takeDamage(a.handle, hh, power);
            knockAway(a);
            setState(a, .knocked_away);
            a.letGo();
        },
    }
}

/// The hold breaks: his holder lets go, he backs off.
fn breakHold(a: Actor) void {
    a.letGo();
    setState(a, .back_off);
}

/// The damage a holder's blow of the hold does (its move's).
fn holderPower(a: Actor, holder: *const Entity) i16 {
    const mv = holder.move orelse return 0;
    return std.math.cast(i16, a.tick.kindOf(holder).definition.moves[mv].damage) orelse 0;
}

/// His holder's request at this tick.
fn reaction(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const hh = m.hitter orelse return;
    const holder = a.other(hh) orelse return;
    switch (request(a, holder)) {
        0 => {
            a.letGo();
            setState(a, .back_off);
        },
        3 => {
            m.step = 2;
            hurt(a, hh, holderPower(a, holder));
            if (m.state == .knocked_away) a.letGo();
        },
        4 => {
            m.ticks = 6;
            m.step = 4;
        },
        5, 7 => setState(a, .thrown),
        6 => setState(a, .thrown_over),
        9 => m.ticks = n.lie_ticks,
        else => {},
    }
}

/// The one thrown's places by the holder's character, row `row` at the holder's frame: across
/// (the other way for a negative `way`) and in height.
fn throwPlace(a: Actor, row: usize, way: i16) void {
    const m = a.mind;
    const hh = m.hitter orelse return;
    const holder = a.other(hh) orelse return;
    const t = a.tables();
    const name = a.tick.kindOf(holder).definition.name;
    const xs: *const [12]i16, const hs: *const [12]i16 = if (std.mem.eql(u8, name, "adam"))
        .{ &t.throw_x_adam, &t.throw_height_adam }
    else if (std.mem.eql(u8, name, "blaze"))
        .{ &t.throw_x_blaze, &t.throw_height_blaze }
    else
        .{ &t.throw_x_axel, &t.throw_height_axel };
    const i = row * 4 + @min(holder.animation.frame, 3);
    var dx: i32 = xs[i];
    if (way < 0) dx = -dx;
    a.entity.position.x = a.entity.position.x.add(.pixels(dx));
    a.entity.position.height = a.entity.position.height.add(.pixels(hs[i]));
}

/// At his holder's place.
fn toHolder(a: Actor) void {
    const hh = a.mind.hitter orelse return;
    const holder = a.other(hh) orelse return;
    a.entity.position = holder.position;
}

/// Thrown over the player's head: at its place by the throw's offsets, a while, while the player
/// keeps him there; its slam slams him down; else he backs off.
fn thrownOver(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (m.step == 0) {
        a.pause(true);
        const holder = if (m.hitter) |h| a.other(h) else null;
        const left = if (holder) |h| h.facingLeft() else false;
        m.dir = if (left) 1 else -1;
        a.animate(.thrown_over);
        a.pause(true);
        a.entity.facing = if (left) .left else .right;
        toHolder(a);
        throwPlace(a, 0, m.dir);
        a.entity.velocity.depth = .zero;
        m.ticks = n.thrown_over_ticks;
        m.step = 1;
        hidePart(a);
        return;
    }
    const free = m.let_go;
    m.let_go = false;
    if (!free) {
        m.ticks -%= 1;
        if (m.ticks != 0) {
            const holder = if (m.hitter) |h| a.other(h) else null;
            const r = if (holder) |h| request(a, h) else 0;
            if (r == 6) return setState(a, .slammed);
            if (r == 2) return;
        }
    }
    setState(a, .back_off);
}

/// Slammed down by the player: following its frames, and at its third the shake and the thud;
/// a while later he is knocked away with the slam's damage.
fn slammed(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const holder = if (m.hitter) |h| a.other(h) else null;
    const hf: u8 = if (holder) |h| h.animation.frame else 0;
    switch (m.step) {
        0, 1 => {
            if (m.step == 0) {
                if (hf == 0) return;
                m.stage = hf;
                a.setFrame(a.frame() + 1);
                m.step = 1;
                throwPlace(a, 1, m.dir);
            }
            if (hf == m.stage) return;
            m.stage = hf;
            if (hf == 3) {
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
            a.setFrame(3);
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
            a.tick.takeDamage(a.handle, m.hitter, n.slammed_damage);
        },
    }
}

/// Thrown by the player: along its facing, up and across; at the top placed on and falling; on
/// the ground a shake, the thud and a bounce; then the throw's damage (his health gone, knocked
/// out) and he slides a little before getting up. Thrown, he strikes what he meets.
fn thrown(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    switch (m.step) {
        0 => {
            a.pause(true);
            hidePart(a);
            const holder = if (m.hitter) |h| a.other(h) else null;
            var way: i16 = 1;
            if (holder) |h| {
                if (h.facingLeft()) way = -1;
                if (std.mem.eql(u8, a.tick.kindOf(h).definition.name, "blaze")) way = -way;
            }
            m.dir = way;
            a.animate(.thrown);
            a.pause(true);
            e.facing = if (way < 0) .left else .right;
            a.setFrame(1);
            m.step = 1;
            if (m.hitter) |h| e.missile = .{ .by = h, .damage = @intCast(n.thrown_damage) };
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
            if (e.velocity.height.raw < 0) {
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
            const ground = a.tick.world.ground;
            if (e.position.height.whole() < ground.whole()) {
                e.velocity.height = e.velocity.height.add(m.gravity);
                return move(a);
            }
            a.tick.shake();
            a.sound(.thud);
            e.position.height = .pixels(ground.whole());
            e.velocity.height = n.thrown_bounce;
            m.ticks = 0;
            m.step = 3;
            move(a);
        },
        3 => {
            fall(a);
            if (m.ticks != n.lie_ticks) return;
            e.missile = null;
            a.tick.takeDamage(a.handle, m.hitter, n.thrown_damage);
            if (e.health > 0) {
                e.velocity.x = e.velocity.x.shr(1);
                e.velocity.height = .zero;
                m.ticks = n.thrown_slide;
                m.step = 4;
                return;
            }
            a.sound(.cry);
            m.step = 0;
            knockout(a);
        },
        else => {
            m.ticks -%= 1;
            if (m.ticks != 0) return move(a);
            m.let_go = false;
            setState(a, .get_up);
        },
    }
}

// Knocked out ---------------------------------------------------------------------------------------

/// Knocked out: (a variant at once its points and its blink) he rises, sits, drops shaking with
/// the thud, gives his points and blinks out; then he is done.
fn knockedOut(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    switch (m.step) {
        0 => {
            if (e.spawn.traits.twin) {
                m.ticks = n.blink_ticks;
                m.step = 4;
                return points(a);
            }
            animate(a, .get_up);
            m.ticks = n.knocked_out_rise;
            m.step = 1;
            partUp(a);
            aim(a);
            if (partActor(a)) |p| part_mod.face(p, e.facingLeft());
            placePart(a, 2);
        },
        1 => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            m.step = 2;
            m.ticks = n.knocked_out_rise;
            animate(a, .struck);
            hidePart(a);
        },
        2 => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            m.ticks = n.knocked_out_drop;
            m.dir = n.knocked_out_shake;
            e.velocity.x = e.velocity.x.neg();
            animate(a, .knocked);
            a.pause(true);
            a.setFrame(1);
            e.velocity.depth = .zero;
            m.step = 3;
            e.position.height = .pixels(a.tick.world.ground.whole());
            a.sound(.thud);
            if (partOf(a)) |p| {
                p.flags.hidden = true;
                p.animation.paused = true;
                p.animation.frame = 0;
            }
        },
        3 => {
            m.ticks -%= 1;
            if (m.ticks != 0) {
                e.position.height = e.position.height.add(.pixels(m.dir));
                m.dir = -m.dir;
                return;
            }
            e.position.height = .pixels(a.tick.world.ground.whole());
            m.ticks = n.blink_ticks;
            m.step = 4;
            points(a);
        },
        4 => {
            m.ticks -%= 1;
            if (m.ticks == 0) {
                m.step = 5;
                return;
            }
            if (m.ticks > n.blink_from) return;
            e.flags.shadowless = true;
            if (m.ticks < n.blink_hidden) {
                e.flags.hidden = true;
                return;
            }
            if (m.ticks & 1 == 1) e.flags.hidden = !e.flags.hidden;
        },
        else => ended(a),
    }
}

/// After his knockout: with a helper left he is done (the helper clears him); else his part
/// goes, and the round is won, or (one whose beating is not the round's end) he goes as an
/// enemy, counted off as a boss.
fn ended(a: Actor) void {
    const m = a.mind;
    if (helperOf(a) != null) {
        m.done = true;
        return;
    }
    if (m.part) |p| if (a.other(p) != null) a.tick.world.remove(p);
    m.part = null;
    if (a.entity.spawn.traits.goes_as_enemy) {
        a.remove();
        return script.bossCountedOff(a.tick);
    }
    if (m.step != 6) a.tick.roundWon();
    m.step = 6;
}

/// His points: to the player whose special attack knocked him out, else the one who hit him last.
fn points(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const w = a.tick.world;
    var second = false;
    if (m.special_ko) {
        m.special_ko = false;
        second = m.special_p2;
        m.special_p2 = false;
    } else if (m.target) |t| {
        second = if (w.players[0].entity) |p1| !p1.eql(t) else true;
    }
    const p = &w.players[if (second) 1 else 0];
    p.score = @min(p.score +| n.points, w.score_most);
}

/// Done with his knockout (for the helper).
pub fn isDone(m: *const Mind) bool {
    return m.done;
}
