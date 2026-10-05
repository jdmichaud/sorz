//! The brawler of round 1. It follows its target to its place beside it (`follow`), its look
//! turned as its target's: each time its target, after facing another way, faces its way again,
//! it counts one; after a few, or a few stops at its place, it closes in (`close_in`) and punches
//! (a blow that knocks down), at its place beside its target, while its target is not down or
//! hurt; once, or up to its punches after shrugging off a blow. Out of time it takes up the fight
//! again (or walks off, placed to). Struck (`hit`), it reels at the next tick (`reel`), or,
//! placed to, shrugs the blow off (`shrug_off`: the blow's damage taken, it stands while its
//! striker is near, then closes in to punch it). Placed in a rolling shutter, it comes in through
//! it as a Galsia does (`shutter_entry`). Its common states are every enemy's (enemy.zig); its
//! numbers, animations, punch and sounds are its definition's (`entities/brawler.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const enemy = @import("enemy.zig");
const behaviours = @import("../behaviours.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());
const Common = enemy.Of(@This());

pub const State = enum {
    appear,
    choose,
    hit,
    knocked_down,
    stand,
    held,
    knocked_out,
    walk_off,
    close_in,
    follow,
    shutter_entry,
    reel,
    shrug_off,
};

pub const fights: State = .choose;
/// A blow puts it in `hit`, which turns to its reel or its shrug at its next tick.
pub const reels: State = .hit;
/// Out of its shutter it takes up the fight as one placed to follow (its record cleared).
pub const plain_entrance: entity.Entrance = .follow;

pub const countdowns = [_]State{ .follow, .close_in, .shrug_off, .stand };

pub const Mind = struct {
    state: State = .appear,
    body: enemy.Body = .{},
    /// Its counts, as the original's bytes: following, its target's turns and its stops;
    /// closing in, its punches and its ticks. Its follow's ticks, whose second bit marks its
    /// target facing another way.
    turns: u8 = 0,
    stops: u8 = 0,
    ticks: u8 = 0,
    /// Its punch is under way; it punches more than once (after a shrug).
    punching: bool = false,
    again: bool = false,
};

pub const Animation = enum { walk, down, reel, stand, thrown, slammed, punch };
pub const Move = enum { punch };
pub const Sound = enum { hurt, thud, cry, cry_odd, shrug };

pub const Numbers = enemy.Numbers(enemy.merged(struct {
    /// Following: its speed, its walk's first frame's ticks, its target's turns and its stops
    /// before it closes in, its ticks.
    follow_speed: Fixed,
    follow_first: u8,
    follow_turns: u8,
    follow_stops: u8,
    follow_ticks: u8,
    /// Closing in after a shrug: its frames' pace, its punches, its ticks; how far beside its
    /// target it walks to; the frame its punch ends at.
    close_in_pace: u8,
    close_in_punches: u8,
    close_in_ticks: u8,
    close_in_beside: i16,
    punch_ends: u8,
    /// The shrug: the frame it shows of its fall, how long at most, how near its striker
    /// keeps it standing.
    shrug_frame: u8,
    shrug_ticks: u8,
    shrug_near: i16,
    /// Across from the camera's place, the sides it follows within (the latter excluded).
    sides_from: i16,
    sides_to: i16,
}, enemy.ShutterNumbers));

pub const Tables = enemy.Tables(struct {});

/// Shrugging a blow off it takes none: the original's shrug has no test of the blows.
pub fn hurtable(state: State) bool {
    return switch (state) {
        .choose, .hit, .shrug_off, .shutter_entry => false,
        else => true,
    };
}

pub fn begin(a: Actor) void {
    if (a.mind.state == .hit and !a.mind.body.waits) return hitTurns(a);
    if (!Common.setUpDue(a)) return;
    const was = a.mind.state;
    switch (was) {
        .follow => followSetUp(a),
        .close_in => closeInSetUp(a),
        .shrug_off => shrugSetUp(a),
        .shutter_entry => enemy.ShutterEntry(@This()).setUp(a),
        else => Common.setUp(a),
    }
    _ = Common.leftAt(a, was);
}

pub fn think(a: Actor) void {
    defer Common.endTick(a);
    if (!Common.tickStarts(a)) return;
    if (Common.act(a)) return;
    switch (a.mind.state) {
        .choose => choose(a),
        .follow => follow(a),
        .close_in => closeIn(a),
        .shrug_off => shrug(a),
        .shutter_entry => enemy.ShutterEntry(@This()).wait(a),
        else => {},
    }
}

/// It takes up the fight the way it was placed.
fn choose(a: Actor) void {
    if (!Common.chooseTarget(a)) return;
    Common.enter(a, switch (a.entity.spawn.entrance) {
        .shutter => .shutter_entry,
        .close_in => .close_in,
        else => .follow,
    });
}

/// Struck at the last tick: it reels from the next; placed to, it shrugs the blow off now.
fn hitTurns(a: Actor) void {
    if (a.entity.spawn.traits.unflinching) {
        Common.enter(a, .shrug_off);
        return begin(a);
    }
    a.mind.state = .reel;
    a.mind.body.fresh = true;
    Common.setUpOnly(a);
}

// Following ---------------------------------------------------------------------------------------

/// It follows its target to its place beside it, facing it; at its place it stops on its walk's
/// first frame; its target's turns to face its way, or its stops, run out: it closes in; its
/// ticks run out, or it leaves the screen's sides: it walks off.
fn followSetUp(a: Actor) void {
    const n = a.numbers();
    if (!Common.chooseTarget(a)) return;
    a.pause(false);
    Common.faceTarget(a);
    a.animate(.walk);
    a.setTicksLeft(n.follow_first);
    a.mind.body.speed = n.follow_speed;
    a.mind.turns = n.follow_turns;
    a.mind.stops = n.follow_stops;
    a.mind.ticks = n.follow_ticks;
}

fn follow(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.ticks -%= 1;
    if (m.ticks == 0 or !withinSides(a)) return Common.enter(a, .walk_off);
    const t = Common.target(a) orelse return Common.enter(a, fights);
    // Its look against its target's facing (the original compares its walk's number with its
    // target's side): another way marks its count's second bit; the same again counts a turn.
    const walking = a.playing(.walk);
    const same = walking and a.entity.facing == t.facing;
    if (!same) {
        m.ticks |= 2;
    } else if (m.ticks & 2 != 0) {
        m.ticks &= ~@as(u8, 2);
        m.turns -%= 1;
        if (m.turns == 0) return Common.enter(a, .close_in);
    }
    if (!Common.pointByOffsets(a)) return;
    Common.faceTarget(a);
    if (Common.headForPoint(a)) {
        a.setTicksLeft(n.follow_first);
        a.pause(true);
        m.stops -%= 1;
        if (m.stops == 0) Common.enter(a, .close_in);
        return;
    }
    a.pause(false);
    _ = Common.walk(a);
}

/// Whether it is within the screen's sides it follows within.
fn withinSides(a: Actor) bool {
    const n = a.numbers();
    const from_camera = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
    return from_camera >= n.sides_from and from_camera < n.sides_to;
}

// Closing in, punching ------------------------------------------------------------------------------

/// It closes in to its place beside its target, unless it left the screen's middle; after a
/// shrug, its frames paced, for a few punches.
fn closeInSetUp(a: Actor) void {
    const n = a.numbers();
    if (Common.offScreen(a)) return;
    a.pause(false);
    Common.faceTarget(a);
    a.animate(.walk);
    a.mind.punching = false;
    if (!a.mind.again) return;
    a.pace(n.close_in_pace, n.close_in_pace);
    a.mind.turns = n.close_in_punches;
    a.mind.stops = n.close_in_ticks;
}

/// Its ticks run out: it takes up the fight again. While its target is down or hurt, it waits.
/// Its reach meeting its target, it punches; else it walks to beside its target, and takes up the
/// fight there. At its punch's end it punches again while it has punches left.
fn closeIn(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.stops -%= 1;
    if (m.stops == 0) return done(a);
    const t = Common.target(a) orelse return Common.enter(a, fights);
    // The original's states it waits on run from down to knocked down, the side faced counted
    // in: its target knocked down facing left is past them.
    for ([_][]const u8{ "down", "dying", "lying_dead", "hurt", "knocked_down" }) |s| {
        const name = behaviours.stateName(&t.mind) orelse break;
        if (!std.mem.eql(u8, name, s)) continue;
        if (std.mem.eql(u8, s, "knocked_down") and t.facingLeft()) break;
        return;
    }
    if (!m.punching) {
        if (!Common.boxMeetsTarget(a, a.kind.definition.box("punch_reach").?)) {
            Common.pointBeside(a, n.close_in_beside);
            if (Common.headForPoint(a)) return done(a);
            _ = Common.walk(a);
            return;
        }
        m.punching = true;
        Common.faceTarget(a);
        a.startMove(.punch);
    }
    if (a.frame() != n.punch_ends) return;
    if (!m.again) return done(a);
    a.endMove();
    Common.faceTarget(a);
    a.animate(.walk);
    m.punching = false;
    m.turns -%= 1;
    if (m.turns == 0) done(a);
}

/// It takes up the fight again; placed to, it walks off.
fn done(a: Actor) void {
    a.endMove();
    a.entity.animation.pace = null;
    a.mind.again = false;
    Common.enter(a, if (a.entity.spawn.traits.walks_off) .walk_off else fights);
}

// Shrugging off -------------------------------------------------------------------------------------

/// The blow's damage taken (the last of its health: knocked down), it stands on its shrug's
/// frame a while, with its sound; its striker far, or its time out, it closes in to punch it a
/// few times.
fn shrugSetUp(a: Actor) void {
    const n = a.numbers();
    const b = &a.mind.body;
    const s = Common.striker(a);
    const damage: i16 = if (s) |x| a.tick.power(x) else 0;
    a.takeDamage(b.other, damage);
    if (a.entity.health < 0) return Common.enter(a, .knocked_down);
    a.sound(.shrug);
    Common.faceTarget(a);
    a.animate(.down);
    a.setFrame(n.shrug_frame);
    a.pause(true);
    a.mind.ticks = n.shrug_ticks;
}

fn shrug(a: Actor) void {
    const n = a.numbers();
    a.mind.ticks -%= 1;
    if (a.mind.ticks != 0) {
        Common.conveyed(a);
        const s = Common.striker(a) orelse return;
        if (@abs(s.position.x.whole() - a.entity.position.x.whole()) < n.shrug_near) return;
    }
    a.mind.again = true;
    Common.enter(a, .close_in);
}

// The hooks ---------------------------------------------------------------------------------------

pub fn struck(a: Actor, blow: tick.Blow) bool {
    return Common.struck(a, blow);
}

pub fn fall(a: Actor) void {
    Common.fall(a);
}

pub fn walls(a: Actor) void {
    Common.walls(a);
}

pub fn landed(a: Actor) void {
    Common.landed(a);
}

pub fn grabbable(a: Actor, by: Handle) bool {
    return Common.grabbable(a, by);
}

pub fn heldBy(a: Actor, holder: Handle) void {
    Common.heldBy(a, holder);
}

pub fn letGoBy(a: Actor, holder: Handle) void {
    Common.letGoBy(a, holder);
}

pub fn knockedBack(a: Actor) void {
    Common.knockedBack(a);
}

pub fn specialCalled(a: Actor) void {
    Common.specialCalled(a);
}

pub fn specialKnockedDown(a: Actor, by: ?Handle, how: tick.Tick.SpecialFall) bool {
    return Common.specialKnockedDown(a, by, how);
}

pub fn letOut(a: Actor) void {
    enemy.ShutterEntry(@This()).letOut(a);
}

/// Taken up following since `elapsed` ticks: its count gone down by them, its target's turns
/// counted as its count's second bit has them, the target facing as it does now.
pub fn takeUp(a: Actor, elapsed: u32) void {
    Common.takeUp(a, elapsed);
    if (a.mind.state != .follow or elapsed == 0) return;
    const t = Common.target(a) orelse return;
    const m = a.mind;
    for (0..@min(elapsed, 255)) |_| {
        m.ticks -%= 1;
        if (m.ticks <= 1) return;
        if (a.entity.facing != t.facing) {
            m.ticks |= 2;
        } else if (m.ticks & 2 != 0) {
            m.ticks &= ~@as(u8, 2);
            if (m.turns > 1) m.turns -= 1;
        }
    }
}

pub fn takeUpHeld(a: Actor, elapsed: u32) void {
    Common.takeUpHeld(a, elapsed);
}

pub fn takeUpCourse(a: Actor, ago: u32, draws: []const u16) void {
    Common.takeUpCourse(a, ago, draws);
}

pub fn takeUpFrame(a: Actor, shown: u32, ago: u32, draws: []const u16) bool {
    return Common.takeUpFrame(a, shown, ago, draws);
}

pub fn takeUpBounces(a: Actor, times: u8) void {
    Common.takeUpBounces(a, times);
}

pub fn takeUpStruck(a: Actor, ago: u32, striking: bool) void {
    Common.takeUpStruck(a, ago, striking);
}
