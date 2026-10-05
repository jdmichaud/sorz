//! The pipe Galsia of round 1: a Galsia with a pipe. Out of hiding it takes up its pipe (a
//! weapon of its own, weapon.zig: its second pipe when its spawn record says so) and heads for its
//! place beside its target (`approach`); there it stands a moment (`wait`), then, level with its
//! target, closes in (`close_in`) and swings (`swing`); not level, it turns its place over in
//! depth and closes in, or walks off. Its common states are every enemy's (enemy.zig); its pipe is
//! seen in its hand only in the frames that hold it. Knocked down, it drops its pipe and fights on
//! as a plain Galsia (galsia.zig), its blows doing its own damage. Its numbers, animations, swing
//! and sounds are its definition's (`entities/galsia_pipe.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const enemy = @import("enemy.zig");
const galsia = @import("galsia.zig");

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
    wait,
    swing,
    close_in,
};

pub const fights: State = .approach;

pub const countdowns = [_]State{ .approach, .wait, .close_in, .swing, .stand };

pub const Mind = struct {
    state: State = .appear,
    body: enemy.Body = .{},
    /// The swing's sound was asked for.
    swung: bool = false,
};

/// It walks off as it was, its pipe in hand (its walk, its side kept).
pub const walks_off_as_it_was = true;

pub const Animation = enum { walk, down, reel, stand, thrown, slammed, walk_pipe, walk_pipe_b, swing, swing_b };
pub const Move = enum { swing, swing_b };
pub const Sound = enum { hurt, thud, cry, cry_odd, swing };

pub const Numbers = enemy.Numbers(struct {
    /// Heading for its place: its speed.
    approach_speed: Fixed,
    /// Standing at its place: how long; the depths within which its target is level with it.
    wait_ticks: u8,
    wait_level: i16,
    /// Closing in: its frames' pace, how long, its speed, how far beside its target.
    close_in_pace: u8,
    close_in_ticks: u8,
    close_in_speed: Fixed,
    close_in_beside: i16,
    /// The swing: its frames' pace, the frame its sound comes at, the frame it ends at.
    swing_pace: u8,
    swing_sound_frame: u8,
    swing_ends: u8,
});

pub const Tables = enemy.Tables(struct {});

/// The kinds of its pipe: the first, or the second when its spawn record says so.
const pipe = "pipe";
const pipe_b = "pipe_b";

pub fn hurtable(state: State) bool {
    _ = state;
    return true;
}

pub fn begin(a: Actor) void {
    // Knocked down (a blow, a throw, a flip), it fights on as a plain Galsia from its first tick
    // there; knocked out, it lets its pipe fall.
    if (a.mind.state == .knocked_down) return disarmed(a);
    if (a.mind.state == .knocked_out) Common.drop(a);
    if (!Common.setUpDue(a)) return;
    const was = a.mind.state;
    switch (was) {
        .approach => approachSetUp(a),
        .wait => waitSetUp(a),
        .close_in => closeInSetUp(a),
        .swing => swingSetUp(a),
        else => Common.setUp(a),
    }
    _ = Common.leftAt(a, was);
}

pub fn think(a: Actor) void {
    if (!Common.tickStarts(a)) return;
    if (Common.act(a)) return;
    switch (a.mind.state) {
        .approach => approach(a),
        .wait => wait(a),
        .close_in => closeIn(a),
        .swing => swing(a),
        else => {},
    }
}

/// Its walk, its pipe in hand.
pub fn walkAnimation(a: Actor) Animation {
    return if (a.entity.spawn.traits.pipe_b) .walk_pipe_b else .walk_pipe;
}

/// It heads for its place beside its target, its pipe taken up at its first tick (with no place
/// for it, it is a plain Galsia); there it stands.
fn approachSetUp(a: Actor) void {
    const n = a.numbers();
    a.mind.body.speed = n.approach_speed;
    a.pause(false);
    if (!Common.chooseTarget(a)) return;
    Common.faceTarget(a);
    a.animate(walkAnimation(a));
    a.setTicksLeft(1);
}

fn approach(a: Actor) void {
    if (a.mind.body.weapon == null and !Common.arm(a, if (a.entity.spawn.traits.pipe_b) pipe_b else pipe)) {
        return galsia.takeOver(a.tick, a.handle, a.mind.body, @intCast(Common.power(a)), galsia.fights);
    }
    if (!Common.pointByOffsets(a)) return;
    if (!Common.headForPoint(a)) {
        _ = Common.walk(a);
        return;
    }
    Common.enter(a, .wait);
}

/// It stands a moment on its walk's second frame; then, its target level with it, it closes in;
/// else it turns its place over in depth, and closes in or walks off by its place across.
fn waitSetUp(a: Actor) void {
    Common.faceTarget(a);
    a.animate(walkAnimation(a));
    a.setFrame(1);
    a.pause(true);
    a.mind.body.timer = a.numbers().wait_ticks;
}

fn wait(a: Actor) void {
    const n = a.numbers();
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer != 0) return;
    const t = Common.target(a) orelse return Common.enter(a, fights);
    const dd = t.position.depth.whole() - a.entity.position.depth.whole();
    if (dd > -2 * @as(i32, n.wait_level) and dd <= 2 * @as(i32, n.wait_level)) return Common.enter(a, .close_in);
    a.entity.spawn.offset_depth = -a.entity.spawn.offset_depth;
    // The original reads the ninth bit of its place across.
    Common.enter(a, if (a.entity.position.x.whole() & 0x100 != 0) .walk_off else .close_in);
}

/// It closes in beside its target a while: there it swings, unless it left the screen's
/// middle; out of time it takes up the fight again.
fn closeInSetUp(a: Actor) void {
    const n = a.numbers();
    a.pause(false);
    a.pace(n.close_in_pace, n.close_in_pace);
    a.mind.body.timer = n.close_in_ticks;
    a.mind.body.speed = n.close_in_speed;
}

fn closeIn(a: Actor) void {
    const n = a.numbers();
    a.mind.body.timer -%= 1;
    if (@as(i8, @bitCast(a.mind.body.timer)) < 0) return Common.enter(a, fights);
    Common.faceTarget(a);
    Common.pointBeside(a, n.close_in_beside);
    if (!Common.headForPoint(a)) {
        _ = Common.walk(a);
        return;
    }
    if (Common.offScreen(a)) return;
    Common.enter(a, .swing);
}

/// The swing: its sound at its frame, and the fight again at its last.
fn swingSetUp(a: Actor) void {
    const n = a.numbers();
    Common.faceTarget(a);
    a.startMove(if (a.entity.spawn.traits.pipe_b) .swing_b else .swing);
    a.pause(false);
    a.pace(n.swing_pace, n.swing_pace);
    a.mind.swung = false;
}

fn swing(a: Actor) void {
    const n = a.numbers();
    if (!a.mind.swung and a.frame() == n.swing_sound_frame) {
        a.mind.swung = true;
        a.sound(.swing);
    }
    if (a.frame() != n.swing_ends) return;
    a.endMove();
    a.entity.animation.pace = null;
    Common.enter(a, fights);
}

/// Knocked down: its pipe falls, and it is a plain Galsia from now, its own blows' damage kept.
fn disarmed(a: Actor) void {
    Common.drop(a);
    a.endMove();
    a.entity.animation.pace = null;
    const h = a.handle;
    const t = a.tick;
    galsia.takeOver(t, h, a.mind.body, @intCast(Common.power(a)), .knocked_down);
    t.begin(h);
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

/// Taken up waiting at its place beside its target: its place in depth was the one, of the two
/// sides of its target's depth when it came there, nearer where it stands.
pub fn takeUpPlayersThen(a: Actor, depths: [2]?i32) void {
    if (a.mind.state != .wait) return;
    const th = a.mind.body.target orelse return;
    const then = for (a.tick.world.players, depths) |p, d| {
        if (p.entity != null and p.entity.?.eql(th)) break d orelse return;
    } else return;
    const here = a.entity.position.depth.whole();
    const off: i32 = a.entity.spawn.offset_depth;
    const near = @abs(pointDepth(a, then, off) - here);
    const turned = @abs(pointDepth(a, then, -off) - here);
    if (turned < near) a.entity.spawn.offset_depth = -a.entity.spawn.offset_depth;
}

/// Its place in depth `off` from its target's depth `then` (turned over beyond the depths).
fn pointDepth(a: Actor, then: i32, off: i32) i32 {
    const d = then + off;
    return if (d < 0 or d >= a.numbers().walk_depth_most) d - 2 * off else d;
}

pub fn takeUpHeld(a: Actor, elapsed: u32) void {
    Common.takeUpHeld(a, elapsed);
}

/// Taken up walking off from its wait: it turned its place over in depth then.
pub fn takeUpCameFrom(a: Actor, from: []const u8) void {
    if (a.mind.state != .walk_off or !std.mem.eql(u8, from, "wait")) return;
    a.entity.spawn.offset_depth = -a.entity.spawn.offset_depth;
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

pub fn takeUpWeapon(a: Actor, w: Handle) void {
    Common.takeUpWeapon(a, w);
}
