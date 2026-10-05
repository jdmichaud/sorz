//! A stalker, the Galsia that strikes from behind (round 1's): out of hiding it heads for its
//! place beside its target (`approach`) and lurks there (`lurk`); when its target turns its back,
//! it sneaks up on it (`sneak`) and grabs it from behind (`grab`), holding it while the others
//! strike; a target it cannot hold it knocks down. After lurking it walks off, or closes in and
//! punches (`close_in`, `punch`: the Galsia's, galsia.zig) when placed to. Its common states are
//! every enemy's (enemy.zig); its numbers, animations and sounds are its definition's
//! (`entities/galsia_stalker.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const enemy = @import("enemy.zig");
const galsia = @import("galsia.zig");
const behaviours = @import("../behaviours.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());
const Common = enemy.Of(@This());
const Punk = galsia.Punk(@This());

pub const State = enum {
    appear,
    approach,
    reel,
    knocked_down,
    stand,
    held,
    knocked_out,
    walk_off,
    sneak,
    grab,
    punch,
    close_in,
    lurk,
};

pub const fights: State = .approach;

pub const countdowns = [_]State{ .approach, .lurk, .close_in, .stand };

pub const Mind = struct {
    state: State = .appear,
    body: enemy.Body = .{},
    punk: galsia.PunkMemory = .{},
    /// Sneaking up, it saw its target turn round at this tick's start: it takes no blow nor grab
    /// until its next.
    seen: bool = false,
};

pub const Animation = enum { walk, down, reel, stand, thrown, slammed, punch, grab };
pub const Move = enum { punch, punch_last };
pub const Sound = enum { hurt, thud, cry, cry_odd };

pub const Numbers = enemy.Numbers(enemy.merged(galsia.PunkNumbers, struct {
    /// Heading for its place: its speed and how long.
    approach_speed: Fixed,
    approach_ticks: u8,
    /// Lurking at its place: how long.
    lurk_ticks: u8,
    /// Sneaking up: its frames' pace and its speed.
    sneak_pace: u8,
    sneak_speed: Fixed,
}));

pub const Tables = enemy.Tables(struct {});

pub fn hurtable(state: State) bool {
    _ = state;
    return true;
}

pub fn begin(a: Actor) void {
    a.mind.seen = false;
    if (Common.setUpDue(a)) {
        const was = a.mind.state;
        switch (was) {
            .approach => approachSetUp(a),
            .lurk => lurkSetUp(a),
            .sneak => sneakSetUp(a),
            .grab => grabSetUp(a),
            .close_in => Punk.closeInSetUp(a),
            .punch => Punk.punchSetUp(a),
            else => Common.setUp(a),
        }
        if (Common.leftAt(a, was)) return;
    } else if (a.mind.body.waits or a.mind.body.fresh) return;
    // Sneaking up, it watches its target's back before anything else: turned round, the target
    // sees it, and it takes up the fight again at its next tick, this one's blows and grabs
    // missing it.
    if (a.mind.state == .sneak and !backTurned(a)) {
        Common.enter(a, fights);
        a.mind.body.left = true;
        a.mind.seen = true;
    }
}

pub fn think(a: Actor) void {
    defer Common.endTick(a);
    if (!Common.tickStarts(a)) return;
    if (Common.act(a)) return;
    switch (a.mind.state) {
        .approach => approach(a),
        .lurk => lurk(a),
        .sneak => sneak(a),
        .grab => grab(a),
        .close_in => Punk.closeIn(a),
        .punch => Punk.punch(a),
        else => {},
    }
}

/// It heads for its place beside its target a while; there, or out of time, it lurks.
fn approachSetUp(a: Actor) void {
    const n = a.numbers();
    if (!Common.chooseTarget(a)) return;
    a.pause(false);
    Common.faceTarget(a);
    a.animate(.walk);
    a.mind.body.speed = n.approach_speed;
    a.setTicksLeft(1);
    a.mind.body.timer = n.approach_ticks;
}

fn approach(a: Actor) void {
    const b = &a.mind.body;
    b.timer -%= 1;
    if (b.timer == 0) return Common.enter(a, .lurk);
    if (!Common.pointByOffsets(a)) return;
    Common.faceTarget(a);
    if (Common.headForPoint(a)) return Common.enter(a, .lurk);
    _ = Common.walk(a);
}

/// It lurks at its place a while: its target turning its back, it sneaks up on it; away from
/// its place, or after the while, it walks off (or closes in, placed to).
fn lurkSetUp(a: Actor) void {
    a.pause(true);
    a.mind.body.timer = a.numbers().lurk_ticks;
}

fn lurk(a: Actor) void {
    const b = &a.mind.body;
    if (!Common.pointByOffsets(a)) return;
    if (Common.headForPoint(a)) {
        b.timer -%= 1;
        if (b.timer != 0) {
            if (!backTurned(a)) return;
            a.pause(false);
            return Common.enter(a, .sneak);
        }
    }
    Common.enter(a, if (a.entity.spawn.traits.closes_in_after_lurking) .close_in else .walk_off);
}

/// Whether its target faces away from it.
fn backTurned(a: Actor) bool {
    const t = Common.target(a) orelse return false;
    return if (a.entity.position.x.whole() > t.position.x.whole()) t.facingLeft() else !t.facingLeft();
}

/// It sneaks up on its target's back with its grab's box: meeting the target's body, it grabs it
/// from behind; one holding another, held from behind or getting out of a hold it knocks down
/// instead, and lurks again. Its target turning round, it takes up the fight again.
fn sneakSetUp(a: Actor) void {
    const n = a.numbers();
    if (!Common.chooseTarget(a)) return;
    a.pace(n.sneak_pace, a.ticksLeft());
    a.mind.body.speed = n.sneak_speed;
}

fn sneak(a: Actor) void {
    if (grabs(a)) return;
    Common.pointBeside(a, 0);
    if (!Common.headForPoint(a)) {
        _ = Common.walk(a);
        return;
    }
    Common.enter(a, fights);
}

/// Its grab's box meets its target's body: the target is grabbed from behind, or knocked down.
fn grabs(a: Actor) bool {
    const t = Common.target(a) orelse return false;
    const th = a.mind.body.target.?;
    const box = a.kind.definition.box("sneak_grab") orelse return false;
    if (!Common.boxMeetsTarget(a, box)) return false;
    if (!a.tick.isPlayer(th) or t.holding != null or t.holder != null or escaping(t)) {
        // A blow that knocks down.
        if (!a.tick.struck(th, .{ .attacker = a.handle, .damage = Common.power(a), .reaction = .knock_down, .push = .zero })) return false;
        Common.enter(a, .lurk);
        return true;
    }
    if (!a.tick.catchable(th)) return false;
    a.tick.catchHeld(a.handle, th, true);
    Common.enter(a, .grab);
    return true;
}

/// A target held from behind, getting out of a hold, or throwing its holder.
fn escaping(t: *const entity.Entity) bool {
    const name = behaviours.stateName(&t.mind) orelse return false;
    for ([_][]const u8{ "held_behind", "escape", "grab_blow" }) |s| if (std.mem.eql(u8, name, s)) return true;
    return false;
}

/// It holds its target from behind, facing its way, still, keeping it ahead of itself (as far as
/// the target's kind says, a pixel nearer the back: the whole pixels moved, the fractions kept),
/// while the target stays held; a blow on it frees the target. The target is placed at each of
/// its ticks, the one it leaves the hold at too.
fn grabSetUp(a: Actor) void {
    a.pause(true);
    // Its walk stops; its speed in height stays as it was.
    a.entity.velocity.x = .zero;
    a.entity.velocity.depth = .zero;
}

fn grab(a: Actor) void {
    const t = Common.target(a) orelse return Common.enter(a, fights);
    a.entity.facing = t.facing;
    a.animate(.grab);
    a.pause(true);
    const ahead = a.tick.kindOf(t).definition.number("held_ahead") orelse 0;
    const p = a.entity.position;
    t.position = .{
        .x = .parts(@intCast(p.x.whole() + ahead * t.facing.sign()), t.position.x.frac()),
        .depth = .parts(@intCast(p.depth.whole() - 1), t.position.depth.frac()),
        .height = .parts(@intCast(p.height.whole()), t.position.height.frac()),
    };
    if (a.entity.holding == null) Common.enter(a, fights);
}

pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (a.mind.seen) return false;
    // A blow on it while it holds frees the one held.
    const holding = a.mind.state == .grab and a.entity.holding != null;
    const took = Common.struck(a, blow);
    if (took and holding) a.tick.letGo(a.handle);
    return took;
}

pub fn heldBy(a: Actor, holder: Handle) void {
    // Thrown by the one it held from behind: the hold turned at that one's tick, before its own,
    // it is held from this tick.
    const turned = a.mind.state == .grab;
    Common.heldBy(a, holder);
    if (turned) {
        a.mind.body.waits = false;
        a.mind.body.fresh = false;
    }
}

pub fn fall(a: Actor) void {
    Common.fall(a);
}

pub fn landed(a: Actor) void {
    Common.landed(a);
}

/// Its blow landed: a punch goes on that tick; the one it struck is the last it touched (as
/// galsia.zig's).
pub fn blowLanded(a: Actor, target: Handle) void {
    a.mind.body.landed = true;
    a.mind.body.other = target;
}

pub fn grabbable(a: Actor, by: Handle) bool {
    if (a.mind.state == .grab or a.mind.seen) return false;
    return Common.grabbable(a, by);
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
