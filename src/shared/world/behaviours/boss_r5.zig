//! Round 5's bosses, the twins. Each waits hidden while the art of the twins is copied from the
//! players' (the first to come asks for the copy; both come out when it is over), then sets on a
//! player (of two: the second when both may be set on, the first when neither; else the one kept,
//! or the nearer across as the original measures it), measuring itself against it each tick:
//! - the first of twins walks (`walk`): it stands a while facing its target, then walks at it,
//!   keeping a little off its depth; a target near across makes it leap back, away and up;
//! - a target a little off its depth and near across, it pounces (`swing`, the traces' `throw`):
//!   crouched a while (not from a walk), it jumps at it, a flying kick, a blow that knocks down,
//!   lands, stands a moment, and walks again;
//! - the second of twins (`holding`) walks slower, keeping to its target's depth; its reach
//!   meeting a player on the ground (or it, in the air, a player on its ground) catches it: from
//!   the front when the player faces it, else from behind; a moment later it tosses the player
//!   over (from the front) or slams it down (from behind), and walks again. A target facing it,
//!   near, or moving away a little farther, makes it somersault at it; a target it may not set on
//!   near, on the screen, makes it leap back;
//! - a twin left alone (its twin beaten) turns from one way to the other: as it gets up, at a
//!   pounce's end, at a throw's end, and every second time it decides to walk;
//! - the rest is the bosses' common body (boss.zig): struck, knocked back or down, held and
//!   thrown, the pepper, the special attack, a player's new life, beaten and the round won.
//! Its blows strike only in its pounce (the original sets their power then alone). Its boxes are
//! the players' (its definition's, `entities/boss_r5.json`), as are its numbers, animations and
//! sounds there.
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const systems = @import("../systems.zig");
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
    peppered,
    special_still,
};

/// The traces' names of his states that are not theirs.
pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "throw", .state = .swing },
    .{ .name = "thrown", .state = .tossed },
    .{ .name = "thrown", .state = .vaulted },
    .{ .name = "thrown", .state = .flung },
    .{ .name = "struck_by_bottle", .state = .peppered },
};

/// His move within his walk (one byte of the original's): the first of twins stands, walks or
/// leaps back; the holding one decides, walks, somersaults or leaps back.
const standing = 0;
const walking = 1;
const leaping = 2;
const deciding = 0;
const somersaulting = 2;
const leaping_off = 3;

/// What a hold asks of the one held (the original's reactions): held from the front, from
/// behind; tossed over, slammed down.
pub const Hold = enum(u8) { none = 0, front = 2, behind = 3, slam = 4, toss = 9 };

pub const Mind = struct {
    state: State = .appear,
    /// His move within his walk (`standing`... `leaping_off`), his count (his stand's ticks, his
    /// leap's, his pounce's and his hold's steps), what his hold asks of the one held.
    move: u2 = standing,
    tally: u8 = 0,
    asks: Hold = .none,
    /// He catches and throws (the second of twins, or a twin alone by turns); his turns of
    /// deciding to walk; he keeps his target.
    holding: bool = false,
    alternate: bool = false,
    targeted: bool = false,
    /// He asked for the twins' art to be copied (the first of twins: once).
    copying: bool = false,
    /// He got up (the body notes it as he lies alive).
    rose: bool = false,
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
    /// His target (the one he holds, in his hold); whether it may be set on.
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
    /// The ground under him, his power (his pounce's blow), his place among twins (0 alone, 1
    /// the first, 2 the second) and his twin's place.
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

pub const Animation = enum { stand, walk, knocked, held, held_behind, flight, bounce, down, lifted, flinch, jump, crouch, kick, catch_front, catch_behind, toss, slam, leap, somersault };
pub const Move = enum { pounce };
pub const Sound = enum { hurt, cry, thud, jump, land, shout };

pub const Tables = struct {
    /// Carried over a thrower's head, step by step: back from the thrower, then down.
    carried: [10]i8,
    /// The copy of the twins' art (`World.art_copy`): each step's length in words, which the
    /// picture's next frame transfers; the tick after the last ends it.
    copy_words: [42]u16,
};

pub const Numbers = struct {
    // His own ---------------------------------------------------------------------------------
    /// His pounce: his target in depth nearer than `pounce_far` but not than `pounce_near`,
    /// across nearer than `pounce_reach`; his count from a walk. Nearer than `leap_near` across
    /// he leaps back. His stand's ticks.
    pounce_far: u16,
    pounce_near: u16,
    pounce_reach: u16,
    pounce_from_walk: u8,
    leap_near: u16,
    stand_ticks: u8,
    /// His speeds across (whole pixels): walking, walking holding, somersaulting (toward his
    /// target), leaping back (away). In depth walking: `hover_speed` toward his target from
    /// `hover_band` away, else away; walking holding: by the depth, `level_*`.
    walk_speed: Fixed,
    hold_walk_speed: Fixed,
    somersault_x: Fixed,
    leap_x: Fixed,
    hover_speed: Fixed,
    hover_band: u16,
    level_far: u16,
    level_mid: u16,
    level_near: u16,
    level_far_speed: Fixed,
    level_mid_speed: Fixed,
    level_near_speed: Fixed,
    /// The leap back: at his count `leap_at` he leaps, in depth toward his target, up; then he
    /// falls, his speed down growing by `fall_gravity`, to his ground.
    leap_at: u8,
    leap_depth: Fixed,
    leap_up: Fixed,
    fall_gravity: Fixed,
    /// Catching: the one caught is put this far across from him (in front, from behind); caught
    /// in the air, his count starts here. Leaping off a target he may not set on: nearer than
    /// `leap_off_near`, drawn within the screen. Somersaulting at a target: nearer than
    /// `somersault_near`, or nearer than `somersault_far` going away on his ground; his speed up;
    /// at a frame's first tick (`hop_ticks` left) his frames `hop_up_frame` and `hop_down_frame`
    /// lift him and put him down `hop` pixels.
    catch_front: i16,
    catch_behind: i16,
    catch_airborne: u8,
    leap_off_near: u16,
    leap_off_from: i16,
    leap_off_to: i16,
    somersault_near: u16,
    somersault_far: u16,
    somersault_up: Fixed,
    hop_ticks: u8,
    hop_up_frame: u8,
    hop_down_frame: u8,
    hop: i16,
    /// The pounce's steps by his count: stand again, its end; the jump (up `pounce_up`, whole
    /// pixels, its fraction kept; across `pounce_x`), the shout, the kick.
    pounce_stand_at: u8,
    pounce_end_at: u8,
    pounce_at: u8,
    shout_at: u8,
    kick_at: u8,
    pounce_up: i16,
    pounce_x: Fixed,
    /// The hold's steps by his count: the throw, the toss's end, the slam's.
    throw_at: u8,
    toss_end: u8,
    slam_end: u8,
    // The body's (boss.zig) -------------------------------------------------------------------
    power: u8,
    hardest_health: u8,
    outside_power: u8,
    /// Out of his section, in the round numbered `outside_health_round`, his health is more
    /// (round 8's boss rush).
    outside_health_round: u8,
    outside_health: i16,
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
    pepper_ticks: u8,
    blast_x: Fixed,
    blast_up: Fixed,
    dying_x: Fixed,
    blast_ticks: u8,
    blast_bounces: u8,
    depth_most: i16,
};

/// His walk from its start (the body's resets): his move; his count goes on (the original's
/// common states leave it).
pub fn walkAfresh(a: Actor) void {
    a.mind.move = standing;
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

/// A player he holds from behind does not jump out of his hold.
pub fn holdEscapable(a: Actor) bool {
    _ = a;
    return false;
}

// The tick -----------------------------------------------------------------------------------

/// His tick until his blows are met: a special attack or a player's new life may end it; then
/// his state's first part (his target, measured; the damage of a blow met at the last tick, what
/// his holder does to him). His blows' power is his only in his pounce.
pub fn begin(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    m.ended = false;
    e.flags.still = true;
    e.power = 0;
    e.move = null;
    a.pause(false);
    // With no player in play, he stands frozen.
    if (a.tick.fighting(0) == null and a.tick.fighting(1) == null) {
        if (m.state != .appear) {
            a.pause(true);
            m.ended = true;
        }
        return;
    }
    if (C.special(a) or C.blast(a)) return C.end(a);
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
            e.power = m.power;
            if (!m.holding) e.move = a.kind.move_of[@backingInt(Move.pounce)];
            const t = m.target orelse return C.end(a);
            m.unattackable = !a.tick.attackable(t);
            if (a.other(t)) |o| C.measure(a, o, false);
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
        .walk => if (m.holding) holdingWalk(a) else walk(a),
        .swing => if (m.holding) holds(a) else pounce(a),
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

/// Hidden while his art is copied from the players' (the first of twins asks for it at his
/// first tick); then shown in front: the ground he stands on is his; his twin found, the status
/// bar shows him; his target chosen; the second of twins holds; his power and health by the
/// level; he walks, standing, facing right.
fn appear(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    e.flags.hidden = true;
    e.flags.in_front = false;
    if (a.tick.world.art_copy != null) return;
    if (!e.spawn.traits.twin and !m.copying) {
        m.copying = true;
        a.tick.world.art_copy = 0;
        // His count's first bit marks the copy asked for: his first stand is a tick shorter.
        m.tally = 1;
        return;
    }
    m.ground = e.position.height;
    C.pairUp(a);
    if (C.inFight(a)) C.onBar(a);
    _ = chooseTarget(a);
    m.holding = m.twin == 2;
    e.flags.hidden = false;
    e.flags.in_front = true;
    const s = C.strength(a);
    m.power = s.power;
    e.health = s.health;
    m.state = .walk;
    m.move = standing;
    e.facing = .right;
    a.animate(.stand);
}

/// The kind whose tables give the copy of the twins' art its steps.
pub const kind_name = "boss_r5";

/// The copy of the twins' art (`World.art_copy`, asked for by the first twin's coming, or by the
/// special attack's end in their section) takes its step at the tick's end, after the turns: the
/// step's words of art, transferred at the next frame (`Output.art_copied`); the tick after the
/// last step ends it.
pub fn copyStep(t: *tick.Tick) void {
    const step = t.world.art_copy orelse return;
    const id = t.kinds.find(kind_name) orelse {
        t.world.art_copy = null;
        return;
    };
    const tables: *const Tables = @ptrCast(@alignCast(t.kinds.get(id).tables.?));
    if (step >= tables.copy_words.len) {
        t.world.art_copy = null;
        return;
    }
    t.out.art_copied = tables.copy_words[step];
    t.world.art_copy = step + 1;
}

/// The player he sets on: his holder when held; the only one in play (the first when none is);
/// of two, the second when both may be set on, the first when neither; else his target kept,
/// or the nearer across as the original measures (the second's distance from his place's low
/// byte alone: its register's high byte is 0 then). Chosen, it is kept.
fn chooseTarget(a: Actor) ?Handle {
    const m = a.mind;
    if (m.hold.grabbed) if (m.holder) |h| if (a.other(h) != null) return h;
    const w = a.tick.world;
    const p1 = a.tick.fighting(0);
    const p2 = a.tick.fighting(1);
    const t: ?Handle = if (p2 == null) p1 else if (p1 == null) p2 else pick: {
        const off1 = !a.tick.attackable(p1.?);
        const off2 = !a.tick.attackable(p2.?);
        if (!off1 and !off2) break :pick p2;
        if (off1 and off2) break :pick p1;
        if (m.targeted) return m.target;
        const x = a.entity.position.x.whole();
        const to_first = @abs(x - w.get(p1.?).?.position.x.whole());
        const to_second = @abs((x & 0xFF) - w.get(p2.?).?.position.x.whole());
        break :pick if (to_second >= to_first) p1 else p2;
    };
    m.target = t;
    m.targeted = true;
    return t;
}

// The first of twins --------------------------------------------------------------------------

/// Got up alone, he holds from the next tick; a target he may set on a little off his depth and
/// near across, he pounces (from a walk at once, else crouched first); else his move.
fn walk(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (m.rose) {
        m.rose = false;
        if (m.twin == 0) {
            m.holding = true;
            return;
        }
    }
    if (!m.unattackable and m.move != leaping and m.dd < n.pounce_far and m.dd >= n.pounce_near and m.dx < n.pounce_reach) {
        m.move = standing;
        m.state = .swing;
        if (!a.plays(.stand)) {
            m.tally = n.pounce_from_walk;
            return;
        }
        m.tally = 0;
        return C.faceAndShow(a, .crouch);
    }
    switch (m.move) {
        standing => stand(a),
        walking => walkOn(a),
        else => leap(a),
    }
}

/// A target near across makes him leap back (the tick ends there).
fn leapsBack(a: Actor) bool {
    const m = a.mind;
    if (m.dx >= a.numbers().leap_near) return false;
    m.tally = 0;
    m.move = leaping;
    C.faceAndShow(a, .leap);
    return true;
}

/// He stands a while facing his target (his stand shown afresh after a walk), then walks.
fn stand(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.targeted = false;
    if (leapsBack(a)) return;
    m.tally +%= 1;
    if (m.tally < n.stand_ticks) {
        if (!a.plays(.stand)) C.faceAndShow(a, .stand);
        return;
    }
    m.tally = 0;
    m.move = walking;
    C.faceAndShow(a, .walk);
}

/// He walks at his target, keeping a little off its depth.
fn walkOn(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (leapsBack(a)) return;
    a.entity.velocity.x = if (m.left_of) n.walk_speed.neg() else n.walk_speed;
    // Toward his target's depth from the band away, else away from it.
    var v = n.hover_speed;
    if (m.dd < n.hover_band) v = v.neg();
    a.entity.velocity.depth = if (m.above) v.neg() else v;
    C.move(a);
}

/// The leap back: a few ticks in its pose, then away across, toward his target's depth, up; he
/// falls to his ground and stands.
fn leap(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    m.tally +%= 1;
    if (m.tally < n.leap_at) return;
    if (m.tally == n.leap_at) {
        e.velocity.depth = if (m.above) n.leap_depth.neg() else n.leap_depth;
        e.velocity.height = n.leap_up;
        e.velocity.x = if (m.left_of) n.leap_x else n.leap_x.neg();
        a.sound(.jump);
        return C.move(a);
    }
    fall(a);
}

/// Falling, to his ground; there he lands and stands.
fn fall(a: Actor) void {
    const n = a.numbers();
    if (!C.grounded(a)) {
        a.entity.velocity.height = a.entity.velocity.height.add(n.fall_gravity);
        return C.move(a);
    }
    landsAndStands(a);
}

/// He lands: his sound, still, his count from 0, standing (facing his target), walking.
fn landsAndStands(a: Actor) void {
    const m = a.mind;
    a.sound(.land);
    C.stop(a);
    m.tally = 0;
    m.move = standing;
    m.state = .walk;
    C.faceAndShow(a, .stand);
}

/// The pounce, by his count: crouched (from a stand), he jumps at his target (a sixteenth of the
/// depth between them a tick in depth, up, across), shouts, kicks, falls and lands crouched; at
/// `pounce_stand_at` he stands, at `pounce_end_at` he walks again (alone, holding from then).
/// His blows land all along (the body's: a blow that knocks down).
fn pounce(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    m.tally +%= 1;
    const k = m.tally;
    if (k == n.pounce_stand_at) return C.faceAndShow(a, .stand);
    if (k == n.pounce_end_at) {
        if (m.twin == 0) m.holding = true;
        m.tally = 0;
        m.state = .walk;
        return C.faceAndShow(a, .stand);
    }
    if (k < n.pounce_at) return;
    if (k == n.pounce_at) {
        a.sound(.jump);
        const t = if (m.target) |h| a.other(h) else null;
        const gap: i32 = if (t) |o| o.position.depth.raw - e.position.depth.raw else 0;
        e.velocity.depth = .{ .raw = gap >> 4 };
        e.velocity.height = .parts(n.pounce_up, e.velocity.height.frac());
        e.velocity.x = if (m.left_of) n.pounce_x.neg() else n.pounce_x;
        C.faceAndShow(a, .jump);
        return C.move(a);
    }
    if (k == n.shout_at) a.sound(.shout);
    if (k == n.kick_at) C.faceAndShow(a, .kick);
    if (!C.grounded(a)) {
        e.velocity.height = e.velocity.height.add(n.fall_gravity);
        return C.move(a);
    }
    if (e.velocity.height.raw == 0) return;
    a.sound(.land);
    C.stop(a);
    C.faceAndShow(a, .crouch);
}

// The holding one -------------------------------------------------------------------------------

/// His reach meeting a player on the ground (or he in the air, a player on his ground) catches
/// it, his target one he may set on and he not leaping off; else his move.
fn holdingWalk(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (reachMeets(a)) |p| if (!m.unattackable and m.move != leaping_off) {
        const o = a.other(p).?;
        if (C.grounded(a)) {
            m.tally = 0;
            return catchPlayer(a, p);
        }
        if (o.position.height.whole() == m.ground.whole()) {
            m.tally = n.catch_airborne;
            a.entity.position.height = m.ground;
            return catchPlayer(a, p);
        }
    };
    switch (m.move) {
        deciding => decide(a),
        walking => holdWalk(a),
        somersaulting => somersault(a),
        else => leap(a),
    }
}

/// The player whose body his reach (his frame's attack box, as last drawn) meets: the first
/// player before the second, neither when the first was struck or caught at this tick.
fn reachMeets(a: Actor) ?Handle {
    const box = a.entity.boxes.attack orelse return null;
    for (a.tick.world.players, 0..) |p, k| {
        const h = p.entity orelse continue;
        if (!a.tick.catchable(h)) {
            if (k == 0) return null;
            continue;
        }
        const t = a.tick.world.get(h) orelse continue;
        const body = t.boxes.body orelse continue;
        if (systems.meet(a.entity, &a.kind.definition.boxes[box], t, &a.tick.kindOf(t).definition.boxes[body])) return h;
    }
    return null;
}

/// He catches the player `h`: from the front when it faces him, else from behind; it is put at
/// his depth, on his ground, across from him by the hold; he faces it, in the hold's pose; he
/// holds (his pounce's state) and his hold asks it to be held so.
fn catchPlayer(a: Actor, h: Handle) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const p = a.other(h).?;
    m.move = standing;
    m.state = .swing;
    m.target = h;
    // Right of the player when his place across is not before its (as the original's unsigned
    // difference).
    const right = @as(u16, @truncate(@as(u32, @bitCast(e.position.x.whole())))) >= @as(u16, @truncate(@as(u32, @bitCast(p.position.x.whole()))));
    const front = if (right) !p.facingLeft() else p.facingLeft();
    m.asks = if (front) .front else .behind;
    const offset: i32 = if (front) n.catch_front else n.catch_behind;
    p.position.depth = e.position.depth;
    p.position.height = m.ground;
    p.position.x = .parts(@intCast(e.position.x.whole() + if (right) -offset else offset), p.position.x.frac());
    e.facing = if (right) .left else .right;
    a.animate(if (front) .catch_front else .catch_behind);
    a.tick.catchHeld(a.handle, h, !front);
}

/// A target he may not set on near, drawn on the screen: he leaps off it (the tick ends).
fn leapsOff(a: Actor) bool {
    const n = a.numbers();
    const m = a.mind;
    if (!m.unattackable or m.dx >= n.leap_off_near) return false;
    if (m.drawn <= n.leap_off_from or m.drawn >= n.leap_off_to) return false;
    m.tally = 0;
    m.move = leaping_off;
    C.faceAndShow(a, .leap);
    return true;
}

/// A target facing him, near, or a little farther on his ground going away from him (still on
/// his right counts): he somersaults at it, up and across (the tick ends).
fn somersaults(a: Actor) bool {
    const n = a.numbers();
    const m = a.mind;
    const t = a.other(m.target orelse return false) orelse return false;
    if (m.dx >= n.somersault_near) {
        if (t.position.height.whole() != m.ground.whole() or m.dx >= n.somersault_far) return false;
        const going = t.velocity.x.whole();
        if (if (m.left_of) going >= 0 else going < 0) return false;
    }
    if (if (m.left_of) t.facingLeft() else !t.facingLeft()) return false;
    m.move = somersaulting;
    m.tally = 0;
    a.entity.velocity.height = n.somersault_up;
    a.entity.velocity.x = if (m.left_of) n.somersault_x.neg() else n.somersault_x;
    C.move(a);
    a.sound(.jump);
    C.faceAndShow(a, .somersault);
    return true;
}

/// Alone and got up, he turns to the first one's way; else, not leaping off nor somersaulting,
/// a target he may set on: every second time alone he turns, else he walks at it.
fn decide(a: Actor) void {
    const m = a.mind;
    if (m.rose) {
        m.rose = false;
        if (m.twin == 0) {
            m.holding = false;
            return;
        }
    }
    m.targeted = false;
    if (leapsOff(a)) return;
    if (somersaults(a)) return;
    if (m.unattackable) return;
    const was = m.alternate;
    m.alternate = !m.alternate;
    if (was and m.twin == 0) {
        m.holding = false;
        return;
    }
    m.move = walking;
    C.faceAndShow(a, .walk);
}

/// He walks at his target, slower, toward its depth by how far it is.
fn holdWalk(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    if (leapsOff(a)) return;
    if (somersaults(a)) return;
    a.entity.velocity.x = if (m.left_of) n.hold_walk_speed.neg() else n.hold_walk_speed;
    const v: Fixed = if (m.dd >= n.level_far) n.level_far_speed else if (m.dd >= n.level_mid) n.level_mid_speed else if (m.dd >= n.level_near) n.level_near_speed else .zero;
    a.entity.velocity.depth = if (m.above) v.neg() else v;
    C.move(a);
}

/// In the air, his somersault's frames lift him and put him down at their first ticks; he falls
/// to his ground and stands.
fn somersault(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    if (e.animation.left == n.hop_ticks) {
        if (a.frame() == n.hop_up_frame) {
            e.position.height = e.position.height.sub(.pixels(n.hop));
        } else if (a.frame() == n.hop_down_frame) {
            e.position.height = e.position.height.add(.pixels(n.hop));
        }
    }
    fall(a);
}

/// His hold, by his count, asking the one held at each tick: at `throw_at` he tosses it over
/// (held from the front) or slams it down (from behind), shouting; at the toss's or the slam's
/// end he lands and stands (alone, his first way from then).
fn holds(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    ask(a);
    m.tally +%= 1;
    const k = m.tally;
    if ((k == n.toss_end and m.asks == .toss) or (k == n.slam_end and m.asks == .slam)) {
        if (m.twin == 0) m.holding = false;
        return landsAndStands(a);
    }
    if (k != n.throw_at) return;
    const toss = m.asks == .front;
    m.asks = if (toss) .toss else .slam;
    C.faceAndShow(a, if (toss) .toss else .slam);
    a.sound(.shout);
    ask(a);
}

/// His hold asks the one held (his target) for what it does: held, tossed or slammed, the throw
/// carrying his power.
fn ask(a: Actor) void {
    const m = a.mind;
    const t = m.target orelse return;
    a.tick.askHeld(t, a.handle, @backingInt(m.asks), m.power);
}
