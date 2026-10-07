//! Signal, the mohawked punk of round 1. Out of hiding it heads for its place beside its target
//! (`approach`), runs there slantwise (`diagonal`) and sizes its target up (`size_up`): near, it
//! closes in (`close_in`), or, placed to slide and level with its target, slides in with a kick
//! that knocks down (`slide`). Walking into its target level with it, it holds it (`hold`) and
//! throws it over its head toward the screen's middle; while its target is knocked down it
//! watches (`watch_hold`). Its common states are every enemy's (enemy.zig), but its walk off
//! goes down the street. Its numbers, animations, moves and sounds are its definition's
//! (`entities/signal.json`).
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
    approach,
    reel,
    knocked_down,
    stand,
    held,
    knocked_out,
    walk_off,
    size_up,
    close_in,
    diagonal,
    slide,
    hold,
    watch_hold,
};

pub const fights: State = .approach;

pub const countdowns = [_]State{ .approach, .size_up, .close_in, .stand };

/// Its walk off goes down the street, whatever its target's depth.
pub const walks_off_down = true;

pub const Mind = struct {
    state: State = .appear,
    body: enemy.Body = .{},
    /// The diagonal run has passed its point across (it goes on in depth).
    across: bool = false,
    /// The slide: past its kick, on its last frame.
    slid: bool = false,
    /// The hold: its throw asked; the one it held struck in its hold.
    threw: bool = false,
    broken: bool = false,
};

pub const Animation = enum { walk, down, reel, stand, thrown, slammed, hold, slide };
pub const Move = enum { slide };
pub const Sound = enum { hurt, thud, cry, cry_odd, slide };

pub const Numbers = enemy.Numbers(struct {
    /// Heading for its place: its speed and how long.
    approach_speed: Fixed,
    approach_ticks: u8,
    /// The slantwise run: its speeds across and in depth.
    diagonal_x: Fixed,
    diagonal_depth: Fixed,
    /// Sizing up: how long; from how far it heads for its place again; within how much depth a
    /// target is level with it for a slide.
    size_up_ticks: u8,
    far: Fixed,
    slide_level: i16,
    /// Closing in: its frames' pace, how long, its speed.
    close_in_pace: u8,
    close_in_ticks: u8,
    close_in_speed: Fixed,
    /// The slide: its ticks, its speed and slowing; then its last frame's ticks.
    slide_ticks: u8,
    slide_speed: Fixed,
    slide_slowing: Fixed,
    slide_end_ticks: u8,
    slide_end_frame: u8,
    /// The hold: past this place from the view's left it faces left (but in the round
    /// `hold_right_round`, where it faces right); the one held is put this far behind it; at the
    /// end of its first frame it throws; it ends at this frame.
    hold_middle: i16,
    hold_right_round: ?u8 = null,
    hold_place: i16,
    hold_ends: u8,
});

pub const Tables = enemy.Tables(struct {});

/// Holding a player, it takes no blow.
pub fn hurtable(state: State) bool {
    return state != .hold;
}

pub fn begin(a: Actor) void {
    if (!Common.setUpDue(a)) return;
    const was = a.mind.state;
    switch (was) {
        .approach => approachSetUp(a),
        .diagonal => diagonalSetUp(a),
        .size_up => sizeUpSetUp(a),
        .close_in => closeInSetUp(a),
        .slide => slideSetUp(a),
        .hold => holdSetUp(a),
        .watch_hold => watchSetUp(a),
        else => Common.setUp(a),
    }
    _ = Common.leftAt(a, was);
}

pub fn think(a: Actor) void {
    defer Common.endTick(a);
    if (!Common.tickStarts(a)) return;
    // Walking off, it holds a target it walks into too.
    if (a.mind.state == .walk_off and holdsOrWatches(a)) return;
    if (Common.act(a)) return;
    switch (a.mind.state) {
        .approach => approach(a),
        .diagonal => diagonal(a),
        .size_up => sizeUp(a),
        .close_in => closeIn(a),
        .slide => slide(a),
        .hold => hold(a),
        .watch_hold => watch(a),
        else => {},
    }
}

/// Its target knocked down, it watches; its walk's box meeting its target's body, level with it
/// and free, it holds it from the front. Returns whether its state changed.
fn holdsOrWatches(a: Actor) bool {
    const t = Common.target(a) orelse return false;
    if (stateIs(t, "knocked_down")) {
        Common.enter(a, .watch_hold);
        return true;
    }
    const th = a.mind.body.target.?;
    if (!a.tick.isPlayer(th) or t.holding != null or t.holder != null) return false;
    // A knee keeps its hold to its end, the one kneed knocked away already (the last knee, or
    // one that took the last of its health): the original's player keeps its hold's word.
    if (stateIs(t, "knee") or stateIs(t, "knee_last")) return false;
    if (!Common.reachMeetsTarget(a)) return false;
    if (@abs(t.position.height.whole() - a.entity.position.height.whole()) >= 8) return false;
    if (!a.tick.catchable(th)) return false;
    a.tick.catchHeld(a.handle, th, false);
    Common.enter(a, .hold);
    return true;
}

fn stateIs(t: *const entity.Entity, name: []const u8) bool {
    const s = behaviours.stateName(&t.mind) orelse return false;
    return std.mem.eql(u8, s, name);
}

/// It heads for its place beside its target a while: there it runs slantwise; out of time it
/// sizes its target up.
fn approachSetUp(a: Actor) void {
    const n = a.numbers();
    a.pause(false);
    if (!Common.chooseTarget(a)) return;
    Common.faceTarget(a);
    a.animate(.walk);
    a.setTicksLeft(1);
    a.mind.body.speed = n.approach_speed;
    a.mind.body.timer = n.approach_ticks;
}

fn approach(a: Actor) void {
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer == 0) return Common.enter(a, .size_up);
    if (holdsOrWatches(a)) return;
    Common.faceTarget(a);
    if (!Common.pointByOffsets(a)) return;
    if (!Common.headForPoint(a)) {
        _ = Common.walk(a);
        return;
    }
    Common.enter(a, .diagonal);
}

/// The slantwise run toward its place: across until past it, then in depth (turning back where
/// the street ends) until past it; then it sizes its target up.
fn diagonalSetUp(a: Actor) void {
    const n = a.numbers();
    if (!Common.pointByOffsets(a)) return;
    const b = &a.mind.body;
    a.entity.velocity.x = if (b.dest_x.whole() > a.entity.position.x.whole()) n.diagonal_x else n.diagonal_x.neg();
    a.entity.velocity.depth = if (b.dest_depth.whole() > a.entity.position.depth.whole()) n.diagonal_depth else n.diagonal_depth.neg();
    a.mind.across = false;
}

fn diagonal(a: Actor) void {
    const n = a.numbers();
    const b = &a.mind.body;
    const e = a.entity;
    if (holdsOrWatches(a)) return;
    if (!a.mind.across) {
        if (Common.wallAcross(a)) return Common.enter(a, .walk_off);
        const x = e.position.x.add(e.velocity.x);
        const refused = !Common.acrossAllowed(a, x);
        if (!refused) e.position.x = x;
        if (a.tick.keptOut(a.handle)) return Common.enter(a, .walk_off);
        if (!refused) {
            const past = if (e.velocity.x.raw < 0) e.position.x.whole() < b.dest_x.whole() else e.position.x.whole() >= b.dest_x.whole();
            if (!past) return;
        }
        a.mind.across = true;
    }
    if (Common.wallInDepth(a)) return Common.enter(a, .walk_off);
    const d = e.position.depth.add(e.velocity.depth);
    if (d.lessThan(.pixels(n.walk_depth_least)) or !d.lessThan(.pixels(n.walk_depth_most))) {
        e.velocity.depth = .pixels(-e.velocity.depth.whole());
    } else e.position.depth = d;
    const y = e.position.depth.whole();
    const past = if (e.velocity.depth.raw < 0) y < b.dest_depth.whole() else y >= b.dest_depth.whole();
    if (past) Common.enter(a, .size_up);
}

/// It sizes its target up a while, unless its target swings a weapon or is down: then it walks
/// off. Then, far, it heads for its place again; level with it, placed to slide, it slides;
/// else it closes in.
fn sizeUpSetUp(a: Actor) void {
    if (!Common.inMiddle(a)) return Common.enter(a, .walk_off);
    a.pause(true);
    a.mind.body.timer = a.numbers().size_up_ticks;
}

fn sizeUp(a: Actor) void {
    const n = a.numbers();
    if (holdsOrWatches(a)) return;
    Common.conveyed(a);
    const t = Common.target(a) orelse return Common.enter(a, fights);
    for ([_][]const u8{ "armed_back_attack", "down", "dying", "lying_dead", "hurt", "knocked_down" }) |s| {
        if (stateIs(t, s)) return Common.enter(a, .walk_off);
    }
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer != 0) return;
    if (!distance(a, t).lessThan(n.far)) return Common.enter(a, fights);
    // Level with its target, it slides; but not with a target nearer the street's top than the
    // level's span (the original compares from the target's depth less the span, unsigned).
    if (a.entity.spawn.traits.slides) {
        const ty = t.position.depth.whole();
        const y = a.entity.position.depth.whole();
        if (ty >= n.slide_level and ty - n.slide_level < y and y <= ty + n.slide_level) return Common.enter(a, .slide);
    }
    Common.enter(a, .close_in);
}

/// The original's estimate of the distance to its target: the larger gap (across or in depth)
/// and three eighths of the other.
fn distance(a: Actor, t: *const entity.Entity) Fixed {
    const dx: u32 = @abs(t.position.x.sub(a.entity.position.x).raw);
    const dd: u32 = @abs(t.position.depth.sub(a.entity.position.depth).raw);
    const most = @max(dx, dd);
    const least = @min(dx, dd);
    return .of(@intCast(((least *% 3) >> 3) +% most));
}

/// It closes in on its target's place a while, unless its target is down, swinging, held or
/// thrown; there, or out of time, it takes up the fight again.
fn closeInSetUp(a: Actor) void {
    const n = a.numbers();
    a.pause(false);
    a.pace(n.close_in_pace, n.close_in_pace);
    a.mind.body.timer = n.close_in_ticks;
    a.mind.body.speed = n.close_in_speed;
}

fn closeIn(a: Actor) void {
    if (holdsOrWatches(a)) return;
    a.mind.body.timer -%= 1;
    if (@as(i8, @bitCast(a.mind.body.timer)) < 0) return Common.enter(a, fights);
    const t = Common.target(a) orelse return Common.enter(a, fights);
    for ([_][]const u8{ "knocked_down", "armed_back_attack", "held", "thrown" }) |s| {
        if (stateIs(t, s)) return Common.enter(a, fights);
    }
    Common.faceTarget(a);
    Common.pointBeside(a, 0);
    if (Common.headForPoint(a)) return Common.enter(a, fights);
    _ = Common.walk(a);
}

/// The slide: at its kick's frame, a slide forward, slowing; then a while on its last frame. Its
/// kick knocks down.
fn slideSetUp(a: Actor) void {
    if (!Common.inMiddle(a)) return Common.enter(a, .walk_off);
    a.pause(false);
    Common.faceTarget(a);
    a.startMove(.slide);
    a.mind.body.timer = a.numbers().slide_ticks;
    a.mind.slid = false;
}

fn slide(a: Actor) void {
    const n = a.numbers();
    const b = &a.mind.body;
    if (!a.mind.slid) {
        if (!a.entity.animation.paused) {
            if (a.frame() == 0) return;
            a.sound(.slide);
            a.pause(true);
            a.entity.velocity.x = if (a.entity.facingLeft()) n.slide_speed.neg() else n.slide_speed;
            a.entity.velocity.depth = .zero;
        }
        a.entity.velocity.x = if (a.entity.velocity.x.raw < 0) a.entity.velocity.x.add(n.slide_slowing) else a.entity.velocity.x.sub(n.slide_slowing);
        b.timer -%= 1;
        if (b.timer != 0) {
            _ = Common.walk(a);
            return;
        }
        a.mind.slid = true;
        a.endMove();
        b.timer = n.slide_end_ticks;
        a.setFrame(n.slide_end_frame);
    }
    b.timer -%= 1;
    if (b.timer == 0) Common.enter(a, fights);
}

/// The hold: it faces toward the screen's middle (right in the round `hold_right_round`), the one
/// held put behind it facing its way; at the end of its first frame it throws it over its head;
/// it ends at its last frame, or when the one held is freed.
fn holdSetUp(a: Actor) void {
    const n = a.numbers();
    a.pause(false);
    a.animate(.hold);
    a.entity.facing = .right;
    const round = if (a.tick.plan) |p| p.round.number else 0;
    const turns = n.hold_right_round == null or n.hold_right_round.? != round;
    if (turns and a.tick.world.camera.x.whole() + n.hold_middle <= a.entity.position.x.whole()) a.entity.facing = .left;
    a.mind.threw = false;
    a.mind.broken = false;
    const h = a.entity.holding orelse return;
    const p = a.other(h) orelse return;
    p.facing = a.entity.facing;
    const behind: i32 = if (a.entity.facingLeft()) n.hold_place else -@as(i32, n.hold_place);
    p.position.x = .parts(@intCast(a.entity.position.x.whole() + behind), p.position.x.frac());
    p.position.depth = .parts(@intCast(a.entity.position.depth.whole() - 1), p.position.depth.frac());
}

fn hold(a: Actor) void {
    const n = a.numbers();
    // Let go before its throw, or the one it held struck in its hold, thrown or not: its hold
    // ends.
    if (a.entity.holding == null and (!a.mind.threw or a.mind.broken)) return Common.enter(a, fights);
    if (a.entity.animation.left == 1 and !a.mind.threw) {
        a.mind.threw = true;
        a.tick.throwHeld(a.handle, Common.power(a));
    }
    if (a.frame() == n.hold_ends) Common.enter(a, fights);
}

/// It watches its target while it is knocked down, facing it.
fn watchSetUp(a: Actor) void {
    Common.faceTarget(a);
    a.animate(.walk);
    a.pause(true);
}

fn watch(a: Actor) void {
    const t = Common.target(a) orelse return Common.enter(a, fights);
    if (!stateIs(t, "knocked_down")) return Common.enter(a, fights);
    Common.faceTarget(a);
}

pub fn struck(a: Actor, blow: tick.Blow) bool {
    return Common.struck(a, blow);
}

/// The one it holds was struck in its hold.
pub fn holdBroken(a: Actor) void {
    a.mind.broken = true;
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
    if (a.entity.holding != null) return false;
    return Common.grabbable(a, by);
}

pub fn heldBy(a: Actor, holder: Handle) void {
    Common.heldBy(a, holder);
}

pub fn letGoBy(a: Actor, holder: Handle) void {
    Common.letGoBy(a, holder);
}

/// Brought back at a wall (enemy.zig's `leftBehind`).
pub fn leftBehind(a: Actor) void {
    Common.leftBehind(a);
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

pub fn takeUp(a: Actor, elapsed: u32) void {
    Common.takeUp(a, elapsed);
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
