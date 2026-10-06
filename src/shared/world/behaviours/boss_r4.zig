//! Round 4's boss, with his shoulder (boss_r4_shoulder.zig). He sets on a player (the only one in
//! play; of two, twins each one by turns, the turn changing as he gets up; alone, the farther
//! across, kept until his charge ends):
//! - `walk`: at his target across (half a pixel a tick, a whole one for the second of twins), in
//!   depth keeping a band from it, kept on the screen; a target behind him makes him stop and turn
//!   to it a while;
//! - `swing` (the traces' `charge`): nearer than his reach across he winds up, three looks a
//!   while each, going on as he walked; then he rushes at his target, his shoulder out: across the
//!   way he faces, in depth the distance's share, faster each tick; past his target by a way he
//!   slides on a while, on the screen; then he walks again, his target chosen afresh;
//! - the rest is the bosses' common body (boss.zig): struck, knocked back or down, held and
//!   thrown, the special attack, a player's new life, beaten and the round won.
//! His own frames strike nothing (the original clears his blow's power each tick): his shoulder
//! strikes, a blow that knocks down. The status bar shows his health from his first tick. His
//! numbers, animations and sounds are his definition's (`entities/boss_r4.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const boss = @import("boss.zig");
const shoulder = @import("boss_r4_shoulder.zig");

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
    .{ .name = "charge", .state = .swing },
    .{ .name = "thrown6", .state = .tossed },
    .{ .name = "thrown7", .state = .vaulted },
    .{ .name = "thrown8", .state = .flung },
    .{ .name = "struck_by_bottle", .state = .peppered },
};

/// His step within his state (one byte of the original's for both): walking, he walks or turns;
/// charging, he winds up (three looks), rushes, slides.
const walking = 0;
const turning = 1;
const wind_up = 0;
const wind_up_2 = 1;
const wind_up_3 = 2;
const rushing = 3;
const sliding = 4;

pub const Mind = struct {
    state: State = .appear,
    /// His step within his state (`walking`... `sliding`).
    step: u3 = walking,
    /// The ticks left of his turn or of his wind-up's look; of his slide.
    wait: u8 = 0,
    slide_left: u8 = 0,
    /// Alone, his target is kept until his charge ends; twins take the players by turns, the
    /// turn changing at each tick that follows his getting up.
    targeted: bool = false,
    turn_of_targets: bool = false,
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
    /// The ground under him, his power (his shoulder's blow), his place among twins (0 alone, 1
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

/// `stand` is his walk (his animation 0); `turn` his turn; `wind_up`... his charge's looks.
pub const Animation = enum { stand, turn, wind_up, wind_up_2, wind_up_3, rush, knocked, held, held_behind, flight, bounce, down, lifted, flinch };
pub const Sound = enum { hurt, cry, thud, rush };

pub const Tables = struct {
    /// Carried over a thrower's head, step by step: back from the thrower, then down.
    carried: [10]i8,
};

pub const Numbers = struct {
    // His own ---------------------------------------------------------------------------------
    /// His walk's speed (the second of twins'); in depth, nearer to his target than
    /// `depth_near` he steps away, from `depth_far` nearer, at `depth_speed`; nearer than
    /// `charge_reach` across he charges; his turn's ticks.
    walk_speed: Fixed,
    walk_speed_second: Fixed,
    depth_near: u16,
    depth_far: u16,
    depth_speed: Fixed,
    charge_reach: u16,
    turn_ticks: u8,
    /// The wind-up's looks' ticks; the rush's speed across, its most in depth; its speed-up a
    /// tick, to its most, in depth from `speed_up_depth_from` away; past his target this far
    /// across he slides, this long at most.
    wind_up_ticks: u8,
    wind_up_2_ticks: u8,
    wind_up_3_ticks: u8,
    rush_speed: Fixed,
    rush_depth_most: Fixed,
    speed_up: Fixed,
    speed_most: Fixed,
    speed_up_depth_from: u16,
    passed_by: u16,
    slide_ticks: u8,
    /// The screen, where he was drawn: he walks and winds up within it, slides while within it.
    on_screen_from: i16,
    on_screen_to: i16,
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

/// The kind of his shoulder.
pub const shoulder_kind = "boss_r4_shoulder";

/// His walk from its start (the body's resets).
pub fn walkAfresh(a: Actor) void {
    a.mind.step = walking;
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

// The tick -----------------------------------------------------------------------------------

/// His tick until his blows are met: a special attack or a player's new life may end it; his
/// own frames strike nothing; then his state's first part (his target, measured; the damage of
/// a blow met at the last tick, what his holder does to him).
pub fn begin(a: Actor) void {
    const m = a.mind;
    m.ended = false;
    a.entity.flags.still = true;
    a.entity.power = 0;
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
        .walk, .swing => {
            m.let_go = false;
            const t = chooseTarget(a) orelse return C.end(a);
            m.rose = false;
            m.unattackable = !a.tick.attackable(t);
            C.measure(a, a.other(t).?, false);
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
        .swing => charge(a),
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

/// His first tick: shown; the ground he stands on is his; his twin found, the status bar shows
/// him; his target chosen; his power and health by the level; he walks, facing right.
fn appear(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    e.flags.hidden = false;
    m.ground = e.position.height;
    C.pairUp(a);
    if (C.inFight(a)) C.onBar(a);
    _ = chooseTarget(a);
    const s = C.strength(a);
    m.power = s.power;
    e.health = s.health;
    m.state = .walk;
    m.step = walking;
    e.facing = .right;
    a.animate(.stand);
}

/// The one he measures himself against at this tick: his holder while held; else the only
/// player in play; of two, twins each one by turns (the first player 1 first, the second player
/// 2), the turn changing at each tick after he got up; alone, the target he chose, kept until his
/// charge ends, else the farther across (player 2 at a tie).
fn chooseTarget(a: Actor) ?Handle {
    const m = a.mind;
    if (m.hold.grabbed) if (m.holder) |h| if (a.other(h) != null) return h;
    const p1 = a.tick.fighting(0);
    const p2 = a.tick.fighting(1);
    const chosen: Handle = pick: {
        if (p1 == null or p2 == null) break :pick p1 orelse p2 orelse return null;
        if (m.rose) m.turn_of_targets = !m.turn_of_targets;
        switch (m.twin) {
            1 => break :pick if (m.turn_of_targets) p2.? else p1.?,
            2 => break :pick if (m.turn_of_targets) p1.? else p2.?,
            else => {},
        }
        const kept = m.targeted;
        m.targeted = true;
        if (kept) if (m.target) |t| if (a.other(t) != null) return t;
        const x = a.entity.position.x.whole();
        const first = @abs(a.other(p1.?).?.position.x.whole() - x);
        const second = @abs(a.other(p2.?).?.position.x.whole() - x);
        break :pick if (second < first) p1.? else p2.?;
    };
    m.target = chosen;
    return chosen;
}

// Walking ------------------------------------------------------------------------------------

/// Turning, he waits, then walks facing his target. Walking, a target behind him makes him stop
/// and turn to it; else he walks at it across (facing left, the original reverses his speed's
/// whole pixels' bits: -1/2 for 1/2, -2 for 1), in depth keeping his band from it (nearer he
/// steps away, farther nearer); within his reach across he charges, his frame kept.
fn walk(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (m.step == turning) {
        m.wait -%= 1;
        if (m.wait != 0) return;
        m.step = walking;
        return C.faceAndShow(a, .stand);
    }
    const faces_left = e.facing == .left;
    if (faces_left != m.left_of) {
        C.stop(a);
        m.step = turning;
        m.wait = n.turn_ticks;
        return C.faceAndShow(a, .turn);
    }
    const speed = if (m.twin == 2) n.walk_speed_second else n.walk_speed;
    e.velocity.x = if (faces_left) .parts(@intCast(-speed.whole() - 1), speed.frac()) else speed;
    var depth: Fixed = .zero;
    if (m.dd < n.depth_near) {
        depth = n.depth_speed.neg();
    } else if (m.dd >= n.depth_far) depth = n.depth_speed;
    e.velocity.depth = if (m.above) depth.neg() else depth;
    if (m.dx >= n.charge_reach) return keepOnScreen(a);
    m.wait = n.wind_up_ticks;
    m.state = .swing;
    m.step = wind_up;
    e.facing = if (m.left_of) .left else .right;
    keepShowing(a, .wind_up);
}

/// Drawn off the screen's span at the last tick, he is put back in it across (its fraction
/// kept); then he moves.
fn keepOnScreen(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    const d = a.mind.drawn;
    if (d < n.on_screen_from) {
        e.position.x = e.position.x.add(.pixels(n.on_screen_from - d));
    } else if (d >= n.on_screen_to) {
        e.position.x = e.position.x.sub(.pixels(d - n.on_screen_to));
    }
    C.move(a);
}

/// He shows `which` from the frame he is on, its ticks going on (the original's way into his
/// charge's looks and out of it).
fn keepShowing(a: Actor, which: Animation) void {
    a.retime(which, a.ticksLeft());
    a.showBoxes();
}

// The charge ---------------------------------------------------------------------------------

fn charge(a: Actor) void {
    const n = a.numbers();
    switch (a.mind.step) {
        wind_up => windUp(a, n.wind_up_2_ticks, .wind_up_2),
        wind_up_2 => windUp(a, n.wind_up_3_ticks, .wind_up_3),
        wind_up_3 => {
            a.mind.wait -%= 1;
            if (a.mind.wait != 0) return keepOnScreen(a);
            rush(a);
        },
        rushing => speedUp(a),
        else => slide(a),
    }
}

/// A look of his wind-up: he goes on as he walked; at its end, the next look (facing as he
/// faces, his frame kept).
fn windUp(a: Actor, ticks: u8, next: Animation) void {
    const m = a.mind;
    m.wait -%= 1;
    if (m.wait != 0) return keepOnScreen(a);
    m.wait = ticks;
    m.step += 1;
    keepShowing(a, next);
}

/// The rush: his shoulder out, his grunt; across at its speed the way he faces; in depth toward
/// his target, the distance's share ((dd << 8) / (dx / 2), in 1/256 pixels), at most
/// `rush_depth_most`. He moves from the next tick.
fn rush(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    spawnShoulder(a);
    a.sound(.rush);
    e.velocity.x = if (e.facing == .left) n.rush_speed.neg() else n.rush_speed;
    const half: u32 = @max(m.dx >> 1, 1);
    const share: u32 = @as(u32, @as(u16, @truncate((@as(u32, m.dd) << 8) / half))) << 8;
    const depth: i32 = @intCast(@min(share, @as(u32, @intCast(n.rush_depth_most.raw))));
    e.velocity.depth = .of(if (m.above) -depth else depth);
    m.step = rushing;
    keepShowing(a, .rush);
}

/// Rushing: faster each tick; past his target by `passed_by` across, he slides (faster at this
/// tick still).
fn speedUp(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const passed = (e.facing == .left) != m.left_of;
    if (passed and m.dx >= n.passed_by) {
        m.step = sliding;
        m.slide_left = n.slide_ticks;
    }
    e.velocity.x = faster(n, e.velocity.x);
    if (m.dd >= n.speed_up_depth_from) e.velocity.depth = faster(n, e.velocity.depth);
    C.move(a);
}

/// `v` a tick faster, at most `speed_most`, its way kept (none: forward).
fn faster(n: Numbers, v: Fixed) Fixed {
    const size: u32 = @abs(v.raw) + @as(u32, @intCast(n.speed_up.raw));
    const most: u32 = @intCast(n.speed_most.raw);
    const s: i32 = @intCast(@min(size, most));
    return .of(if (v.raw < 0) -s else s);
}

/// Sliding, at his speeds: once its ticks run out, or he was drawn off the screen's span, he
/// walks again (his frame kept), his target chosen afresh.
fn slide(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.slide_left -%= 1;
    if (m.slide_left != 0 and m.drawn >= n.on_screen_from and m.drawn < n.on_screen_to) return C.move(a);
    m.targeted = false;
    m.step = walking;
    m.state = .walk;
    keepShowing(a, .stand);
}

/// His shoulder, in the first free place after his (none: none), placed at once.
fn spawnShoulder(a: Actor) void {
    const kind = a.tick.kinds.find(shoulder_kind) orelse return;
    const h = a.tick.world.spawnWithin(a.tick.kinds, kind, a.handle.index + 1, 51, .zero, a.entity.facing) catch return;
    if (a.tick.actor(shoulder, h)) |s| shoulder.start(s, a.handle, a.mind.power, a.entity);
}

// Taken up from a situation ------------------------------------------------------------------

/// Taken up from a situation another program recorded, `elapsed` ticks into his state: his
/// ground (the round's), his power, the status bar; drawn where he is; his state's timers gone
/// down by then (his charge's step is not in the situation: he winds up afresh).
pub fn takeUp(a: Actor, elapsed: u32) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const w = a.tick.world;
    if (m.state == .appear) return;
    m.ground = w.ground;
    m.power = C.strength(a).power;
    m.drawn = @intCast(e.position.x.whole() - w.camera.x.whole());
    C.onBar(a);
    const ago: u8 = @intCast(@min(elapsed, 255));
    switch (m.state) {
        .swing => {
            m.step = wind_up;
            m.wait = n.wind_up_ticks -| ago;
            if (m.wait == 0) m.wait = 1;
            a.animate(.wind_up);
        },
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
