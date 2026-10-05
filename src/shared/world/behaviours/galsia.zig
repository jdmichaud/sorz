//! A Galsia, the street punk of round 1. Out of hiding it takes up the fight (`choose`) the way
//! the round's script placed it (`Entity.spawn.entrance`): it closes in beside its target and
//! punches when its reach meets the target's body (`close_in`, `punch`); it heads for its place
//! beside its target and circles there, hesitating, until the tick sends it in (`approach`,
//! `circle`, `hesitate`); it squares up to its target first (`square_up`); it waits at the
//! screen's far edge and flanks a target that is down or held (`edge`, `flank`, `taunt`); it lies
//! in wait until its target comes near (`wait`); it drops out from behind a rolling shutter
//! (`shutter_entry`). Its common states (a reel, a knock-down, a hold, its knockout, a stand, a
//! walk off) are every enemy's (enemy.zig). Its numbers, tables, animations, punch and sounds
//! are its definition's (`entities/galsia.json`).
//!
//! Its punch is a string of three blows: two jabs, and a last punch that knocks down.
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const enemy = @import("enemy.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());
const Common = enemy.Of(@This());

pub const State = enum {
    appear,
    choose,
    reel,
    knocked_down,
    stand,
    held,
    knocked_out,
    walk_off,
    square_up,
    close_in,
    punch,
    circle,
    hesitate,
    approach,
    edge,
    flank,
    taunt,
    wait,
    shutter_entry,
};

/// The state it takes up the fight in.
pub const fights: State = .choose;

/// The states whose count goes down every tick from their set-up (a situation taken up there
/// counts on).
pub const countdowns = [_]State{ .close_in, .approach, .hesitate, .square_up, .wait, .stand };

pub const Mind = struct {
    state: State = .appear,
    body: enemy.Body = .{},
    punk: PunkMemory = .{},
};

pub const Animation = enum { walk, down, reel, stand, thrown, slammed, punch };
pub const Move = enum { punch, punch_last };
pub const Sound = enum { hurt, thud, cry, cry_odd };

pub const Numbers = enemy.Numbers(enemy.merged(PunkNumbers, OwnNumbers));

/// The numbers of the Galsias' close in and punch (a stalker's too).
pub const PunkNumbers = struct {
    /// The punch: the frame whose box is its reach, the frame of its last punch and the frame
    /// that tests it, the frame it ends at; a punch from the edge paces its frames.
    reach_frame: u8,
    last_punch_frame: u8,
    last_punch_test: u8,
    punch_ends: u8,
    edge_punch_pace: u8,
    /// Closing in: its speeds (slower for one placed slow), how long, how far beside its target,
    /// its frames' pace; nearer than `too_close` across it walks off.
    close_in_speed: Fixed,
    close_in_slow: Fixed,
    close_in_ticks: u8,
    close_in_beside: i16,
    close_in_pace: u8,
    too_close: i16,
};

/// The Galsia's own numbers.
const OwnNumbers = struct {
    /// Squaring up: its ticks, and the depths within which its target is level with it.
    square_ticks: u8,
    square_level: i16,
    /// Approaching its place: its ticks and speed.
    approach_ticks: u8,
    approach_speed: Fixed,
    /// The edge: its place across from the view's left or right, and in depth; its speed; the
    /// ticks it waits there; the target's distance that sends it walking off.
    edge_left: i16,
    edge_right: i16,
    edge_depth: i16,
    edge_speed: Fixed,
    edge_ticks: u8,
    edge_near: i16,
    /// Flanking: its place beside its target, and its speed; the taunt's rounds and its frames'
    /// pace, and the frame each round ends at.
    flank_beside: i16,
    flank_speed: Fixed,
    taunts: u8,
    taunt_pace: u8,
    taunt_ends: u8,
    /// Waiting: its ticks, the pose it lies in, and how near its target comes before it gets
    /// up.
    wait_ticks: u8,
    wait_frame: u8,
    wait_near: i16,
};

pub const Tables = enemy.Tables(struct {
    /// Hesitating: its ticks, by the tick's low two bits.
    hesitate: [4]u8,
    /// Circling: the point it heads for, around its place, by a draw's low four bits; its speed
    /// and its frames' pace by its place across's low two bits.
    circle_x: [16]i8,
    circle_depth: [16]i8,
    circle_speed: [4]i32,
    circle_pace: [4]u8,
});

pub const Choices = struct {
    /// What follows a circle, by the tick's low three bits.
    after_circle: [8]State,
};

/// A Galsia's own memory (a stalker's too).
pub const PunkMemory = struct {
    /// The punch's last blow was tested once.
    tested: bool = false,
    /// The circle has left its first frame (it ends when the frame comes back).
    stepped: bool = false,
    /// The punch from the screen's edge: its frames paced.
    from_edge: bool = false,
};

/// Whether a state takes the players' blows and grabs.
pub fn hurtable(state: State) bool {
    return switch (state) {
        .choose, .wait, .shutter_entry => false,
        else => true,
    };
}

pub fn begin(a: Actor) void {
    if (!Common.setUpDue(a)) return;
    const was = a.mind.state;
    switch (was) {
        .close_in => Punk(@This()).closeInSetUp(a),
        .punch => Punk(@This()).punchSetUp(a),
        .circle => circleSetUp(a),
        .hesitate => hesitateSetUp(a),
        .square_up => squareSetUp(a),
        .approach => approachSetUp(a),
        .edge => edgeSetUp(a),
        .flank => flankSetUp(a),
        .taunt => tauntSetUp(a),
        .wait => waitSetUp(a),
        .shutter_entry => shutter(a),
        else => Common.setUp(a),
    }
    _ = Common.leftAt(a, was);
}

pub fn think(a: Actor) void {
    if (!Common.tickStarts(a)) return;
    if (Common.act(a)) {
        // A Galsia placed in a shutter stays hidden once out: the shutter shows it.
        if (a.mind.state == fights and a.entity.spawn.entrance == .shutter and a.mind.body.target != null) a.entity.flags.hidden = true;
        return;
    }
    switch (a.mind.state) {
        .choose => choose(a),
        .close_in => Punk(@This()).closeIn(a),
        .punch => Punk(@This()).punch(a),
        .circle => circle(a),
        .hesitate => hesitate(a),
        .square_up => squareUp(a),
        .approach => approach(a),
        .edge => edge(a),
        .flank => flank(a),
        .taunt => taunt(a),
        .wait => wait(a),
        .shutter_entry => shutter(a),
        else => {},
    }
}

/// It takes up the fight the way it was placed.
fn choose(a: Actor) void {
    if (!Common.chooseTarget(a)) return;
    Common.enter(a, switch (a.entity.spawn.entrance) {
        .edge => .edge,
        .wait => .wait,
        .approach => .approach,
        .shutter => .shutter_entry,
        .square_up => .square_up,
        else => .close_in,
    });
}

/// The Galsias' close in and punch, which the stalker shares: module `M`'s, with its Mind's
/// `punk` and its numbers' `PunkNumbers`.
pub fn Punk(comptime M: type) type {
    return struct {
        const A = tick.Actor(M);
        const C = enemy.Of(M);

        /// It closes in to a point beside its target, at its depth, for a while: there, out of
        /// reach, it walks off; its reach meeting the target's body, it punches.
        pub fn closeInSetUp(a: A) void {
            const n = a.numbers();
            C.faceTarget(a);
            a.animate(.walk);
            a.pause(false);
            a.pace(n.close_in_pace, 1);
            a.mind.body.timer = n.close_in_ticks;
            a.mind.body.speed = if (a.entity.spawn.traits.slow) n.close_in_slow else n.close_in_speed;
        }

        pub fn closeIn(a: A) void {
            const n = a.numbers();
            const b = &a.mind.body;
            b.timer -%= 1;
            if (b.timer == 0) return C.enter(a, M.fights);
            C.pointBeside(a, n.close_in_beside);
            if (C.headForPoint(a)) return C.enter(a, .walk_off);
            if (!C.walk(a)) return;
            _ = inReach(a);
        }

        /// Whether its reach (its first jab's box, wherever its frame is) meets the target's
        /// body: then it punches.
        pub fn inReach(a: A) bool {
            const box = C.frameBox(a, .punch, a.numbers().reach_frame) orelse return false;
            if (!C.boxMeetsTarget(a, box)) return false;
            C.enter(a, .punch);
            return true;
        }

        /// Nearer than its least across, it walks off; else, in reach, it punches. Returns
        /// whether its state changed.
        pub fn tooCloseOrReach(a: A) bool {
            const t = C.target(a) orelse return false;
            if (@abs(t.position.x.whole() - a.entity.position.x.whole()) < a.numbers().too_close) {
                C.enter(a, .walk_off);
                return true;
            }
            return inReach(a);
        }

        /// The punch: a string of blows; at the frame before its last, the last punch's box is
        /// tested once: when it would not reach, the punch ends; from that last punch on, a blow
        /// knocks down.
        pub fn punchSetUp(a: A) void {
            if (C.offScreen(a)) return;
            C.faceTarget(a);
            a.pause(false);
            a.startMove(.punch);
            if (a.mind.punk.from_edge) a.pace(a.numbers().edge_punch_pace, a.numbers().edge_punch_pace);
            a.mind.punk.tested = false;
        }

        pub fn punch(a: A) void {
            const n = a.numbers();
            if (a.frame() >= n.last_punch_frame) a.entity.move = a.kind.move_of[@backingInt(M.Move.punch_last)];
            if (!a.mind.punk.tested and a.frame() == n.last_punch_test) {
                a.mind.punk.tested = true;
                const box = C.frameBox(a, .punch, n.last_punch_frame) orelse return endPunch(a);
                if (!C.boxMeetsTarget(a, box)) return endPunch(a);
            }
            if (a.frame() == n.punch_ends) endPunch(a);
        }

        fn endPunch(a: A) void {
            a.endMove();
            a.mind.punk.from_edge = false;
            a.pause(false);
            a.entity.animation.pace = null;
            C.enter(a, M.fights);
        }
    };
}

const P = Punk(@This());

// Circling and hesitating ------------------------------------------------------------------------

/// It circles: toward a drawn point around its place beside its target, a stretch of the walk
/// at a speed and pace by its place across; when its walk's first frame comes back, the tick
/// says what follows.
fn circleSetUp(a: Actor) void {
    const t = a.tables();
    const b = &a.mind.body;
    Common.faceTarget(a);
    a.animate(.walk);
    a.pause(false);
    a.setFrame(1);
    const r = a.pick(.circle_point, 16);
    if (!Common.pointByOffsets(a)) return;
    b.dest_x = b.dest_x.add(.pixels(t.circle_x[r]));
    b.dest_depth = b.dest_depth.add(.pixels(t.circle_depth[r]));
    const k: usize = @intCast(a.entity.position.x.whole() & 3);
    b.speed = .of(t.circle_speed[k]);
    a.pace(t.circle_pace[k], 1);
    a.mind.punk.stepped = false;
    _ = Common.headForPoint(a);
}

fn circle(a: Actor) void {
    if (P.inReach(a)) return;
    if (a.frame() != 1) {
        a.mind.punk.stepped = true;
        _ = Common.walk(a);
        return;
    }
    if (!a.mind.punk.stepped) {
        _ = Common.walk(a);
        return;
    }
    Common.enter(a, a.choices().after_circle[a.tick.world.tick & 7]);
}

/// It stands a while, by the tick, facing its target; too close it walks off, in reach it
/// punches; then it circles.
fn hesitateSetUp(a: Actor) void {
    Common.faceTarget(a);
    a.animate(.walk);
    a.setFrame(1);
    a.pause(true);
    a.mind.body.timer = a.tables().hesitate[a.tick.world.tick & 3];
}

fn hesitate(a: Actor) void {
    if (P.tooCloseOrReach(a)) return;
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer == 0) Common.enter(a, .circle);
}

// Squaring up, approaching ------------------------------------------------------------------------

/// It squares up to its target a while; too close it walks off, in reach it punches; then, its
/// target level with it, it closes in; else it takes up the fight again.
fn squareSetUp(a: Actor) void {
    if (Common.offScreen(a)) return;
    Common.faceTarget(a);
    a.animate(.walk);
    a.setFrame(1);
    a.pause(true);
    a.mind.body.timer = a.numbers().square_ticks;
}

fn squareUp(a: Actor) void {
    const n = a.numbers();
    if (P.tooCloseOrReach(a)) return;
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer != 0) return;
    const t = Common.target(a) orelse return Common.enter(a, fights);
    const dd = t.position.depth.whole() - a.entity.position.depth.whole();
    Common.enter(a, if (dd > -2 * @as(i32, n.square_level) and dd <= 2 * @as(i32, n.square_level)) .close_in else fights);
}

/// It heads for its place beside its target a while: there it circles; out of time, it
/// hesitates.
fn approachSetUp(a: Actor) void {
    const n = a.numbers();
    if (!Common.chooseTarget(a)) return;
    a.mind.body.timer = n.approach_ticks;
    a.mind.body.speed = n.approach_speed;
    Common.faceTarget(a);
    a.animate(.walk);
    a.pause(false);
    a.setFrame(1);
    a.setTicksLeft(1);
}

fn approach(a: Actor) void {
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer == 0) return Common.enter(a, .hesitate);
    if (!Common.pointByOffsets(a)) return;
    if (Common.headForPoint(a)) return Common.enter(a, .circle);
    _ = Common.walk(a);
}

// The edge, flanking, taunting --------------------------------------------------------------------

/// It goes to the screen's edge on the far side of its target, and waits there while its target
/// stays away: one near sends it walking off; one down, held from behind or idle, it flanks;
/// after a while it punches from there.
fn edgeSetUp(a: Actor) void {
    const n = a.numbers();
    if (!Common.chooseTarget(a)) return;
    Common.faceTarget(a);
    a.animate(.walk);
    a.pause(false);
    a.mind.body.speed = n.edge_speed;
    a.mind.body.timer = n.edge_ticks;
}

fn edge(a: Actor) void {
    const n = a.numbers();
    const b = &a.mind.body;
    const t = Common.target(a) orelse return Common.enter(a, fights);
    const camera = a.tick.world.camera.x.whole();
    const from = if (t.position.x.lessThan(a.entity.position.x)) n.edge_right else n.edge_left;
    b.dest_x = .pixels(camera + from);
    b.dest_depth = .pixels(n.edge_depth);
    Common.faceTarget(a);
    if (!Common.headForPoint(a)) {
        a.pause(false);
        _ = Common.walk(a);
        return;
    }
    a.setFrame(1);
    a.setTicksLeft(1);
    if (@abs(t.position.x.whole() - a.entity.position.x.whole()) < n.edge_near) return Common.enter(a, .walk_off);
    if (targetOpen(a, t)) return Common.enter(a, .flank);
    a.pause(true);
    b.timer -%= 1;
    if (b.timer != 0) return;
    a.mind.punk.from_edge = true;
    Common.enter(a, .punch);
}

/// Whether its target is down, held from behind, or idle (the original reads its state).
fn targetOpen(a: Actor, t: *const entity.Entity) bool {
    _ = a;
    const name = @import("../behaviours.zig").stateName(&t.mind) orelse return false;
    for ([_][]const u8{ "knocked_down", "held_behind", "idle" }) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// It runs to its place right beside its target, level with it (its place stays so), then
/// taunts.
fn flankSetUp(a: Actor) void {
    const n = a.numbers();
    a.entity.spawn.offset_depth = 0;
    a.entity.spawn.offset_x = n.flank_beside;
    Common.faceTarget(a);
    a.animate(.walk);
    a.pause(false);
    a.pace(n.close_in_pace, 1);
    a.mind.body.speed = n.flank_speed;
}

fn flank(a: Actor) void {
    if (!Common.pointByOffsets(a)) return;
    if (!Common.headForPoint(a)) {
        _ = Common.walk(a);
        return;
    }
    Common.enter(a, .taunt);
}

/// The taunt: its punch's frames, played over a few times (its jabs land too), then the fight.
fn tauntSetUp(a: Actor) void {
    const n = a.numbers();
    if (Common.offScreen(a)) return;
    Common.faceTarget(a);
    a.pause(false);
    a.startMove(.punch);
    a.pace(n.taunt_pace, n.taunt_pace);
    a.mind.body.timer = n.taunts;
}

fn taunt(a: Actor) void {
    const n = a.numbers();
    if (a.mind.body.landed) return endTaunt(a);
    if (a.frame() != n.taunt_ends) return;
    a.setFrame(0);
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer == 0) endTaunt(a);
}

fn endTaunt(a: Actor) void {
    a.endMove();
    a.entity.animation.pace = null;
    Common.enter(a, fights);
}

/// Its blow landed: a taunt ends.
pub fn blowLanded(a: Actor, target: Handle) void {
    _ = target;
    a.mind.body.landed = true;
}

// Waiting ---------------------------------------------------------------------------------------

/// It lies in wait, facing its target, until its target comes near or a while passes; then it
/// gets up and closes in as a plain Galsia.
fn waitSetUp(a: Actor) void {
    const n = a.numbers();
    a.pause(true);
    Common.faceTarget(a);
    a.animate(.down);
    a.pause(true);
    a.setFrame(n.wait_frame);
    a.mind.body.timer = n.wait_ticks;
}

fn wait(a: Actor) void {
    const n = a.numbers();
    _ = Common.chooseTarget(a);
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer != 0) {
        const t = Common.target(a) orelse return;
        if (@abs(t.position.x.whole() - a.entity.position.x.whole()) >= n.wait_near) return;
    }
    a.entity.spawn = .{ .offset_x = a.entity.spawn.offset_x, .offset_depth = a.entity.spawn.offset_depth, .strength = a.entity.spawn.strength };
    Common.enter(a, fights);
}

// The shutter -----------------------------------------------------------------------------------

/// TODO: the rolling shutter it waits behind (its own entity); until then it comes out as a
/// plain Galsia.
fn shutter(a: Actor) void {
    a.entity.flags.hidden = false;
    a.entity.spawn.entrance = .close_in;
    Common.enter(a, fights);
}

// The hooks ---------------------------------------------------------------------------------------

pub fn struck(a: Actor, blow: tick.Blow) bool {
    return Common.struck(a, blow);
}

pub fn fall(a: Actor) void {
    Common.fall(a);
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

pub fn specialBlast(a: Actor) void {
    Common.specialBlast(a);
}

pub fn takeUp(a: Actor, elapsed: u32) void {
    Common.takeUp(a, elapsed);
}

pub fn takeUpStruck(a: Actor, ago: u32, striking: bool) void {
    Common.takeUpStruck(a, ago, striking);
}
