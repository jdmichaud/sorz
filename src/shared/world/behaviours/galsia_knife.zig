//! The knife Galsia of round 1: a Galsia with a knife. It takes up a knife (a weapon of its own,
//! knife.zig) as it takes up the fight, and closes in to its place beside its target
//! (`close_in`), or, placed so, rushes at its target and past it, slowing down (`jump_in`); there
//! it sizes its target up (`size_up`, a while, facing it). Then, not level with it, it walks off;
//! level and near it stabs (`stab`: when its reach meets its target, again while it still does;
//! else it walks beside its target, and walks off there); level and far it throws its knife
//! (`throw`) and takes up the fight again, a new knife in hand. One that rushed in takes up the
//! fight again after sizing up.
//!
//! Knocked down, it drops its knife and fights on as a plain Galsia (galsia.zig), its blows its
//! own; one that rushed in keeps its knife, unless the blow took the last of its health.
//! Knocked out, it lets its knife fall. Its common states are every enemy's (enemy.zig); its knife
//! is seen in its hand only in the frames that hold it. Its numbers, animations, stab and sounds
//! are its definition's (`entities/galsia_knife.json`).
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
    choose,
    reel,
    knocked_down,
    stand,
    held,
    knocked_out,
    walk_off,
    size_up,
    stab,
    throw,
    jump_in,
    close_in,
};

pub const fights: State = .choose;

pub const countdowns = [_]State{ .size_up, .close_in, .stab, .throw, .stand };

pub const Mind = struct {
    state: State = .appear,
    body: enemy.Body = .{},
    /// Its rush passed its target; its stab is under way; its knife left its hand.
    passed: bool = false,
    stabbing: bool = false,
    threw: bool = false,
    /// Knocked down, it has seen whether it keeps its knife.
    downed: bool = false,
};

/// It walks off as it was, its knife in hand (its walk, its side kept).
pub const walks_off_as_it_was = true;

pub const Animation = enum { walk, down, reel, stand, thrown, slammed, walk_knife, jump_in, stab, throw };
pub const Move = enum { stab, jump_in };
pub const Sound = enum { hurt, thud, cry, cry_odd, throw };

pub const Numbers = enemy.Numbers(struct {
    /// The rush: its speed, its frames' pace once past its target, its slowing a tick.
    jump_in_speed: Fixed,
    jump_in_pace: u8,
    jump_in_slowing: Fixed,
    /// Closing in: its speed; the ticks of its walk's first frame.
    close_in_speed: Fixed,
    close_in_first: u8,
    /// Sizing up: how long; the depths within which its target is level with it (each side's).
    size_up_ticks: u8,
    size_up_level: i16,
    /// The stab: nearer than this across it stabs, else it throws; its speed, how far beside
    /// its target it walks to, its frames' pace, the frame it strikes again at.
    stab_near: i16,
    stab_speed: Fixed,
    stab_beside: i16,
    stab_pace: u8,
    stab_again: u8,
    /// The throw: the frame its knife leaves its hand at, the frame it ends at.
    throw_frame: u8,
    throw_ends: u8,
});

pub const Tables = enemy.Tables(struct {});

/// The kind of its knife.
const knife = "knife";

pub fn hurtable(state: State) bool {
    _ = state;
    return true;
}

pub fn begin(a: Actor) void {
    if (a.mind.state != .knocked_down) a.mind.downed = false;
    if (a.mind.state == .knocked_down and !a.mind.downed) {
        a.mind.downed = true;
        if (knockedDown(a)) return;
    }
    if (a.mind.state == .knocked_out) Common.drop(a);
    if (!Common.setUpDue(a)) return;
    const was = a.mind.state;
    switch (was) {
        .jump_in => jumpInSetUp(a),
        .close_in => closeInSetUp(a),
        .size_up => sizeUpSetUp(a),
        .stab => stabSetUp(a),
        .throw => throwSetUp(a),
        else => Common.setUp(a),
    }
    _ = Common.leftAt(a, was);
}

pub fn think(a: Actor) void {
    if (!Common.tickStarts(a)) return;
    if (Common.act(a)) return;
    switch (a.mind.state) {
        .choose => choose(a),
        .jump_in => jumpIn(a),
        .close_in => closeIn(a),
        .size_up => sizeUp(a),
        .stab => stab(a),
        .throw => throw(a),
        else => {},
    }
}

/// It takes up the fight the way it was placed.
fn choose(a: Actor) void {
    if (!Common.chooseTarget(a)) return;
    Common.enter(a, switch (a.entity.spawn.entrance) {
        .jump_in => .jump_in,
        .size_up => .size_up,
        else => .close_in,
    });
}

/// It has a knife in hand, a new one taken up when it has none; with no place for one, it is a
/// plain Galsia from now: whether it is still armed.
fn armed(a: Actor) bool {
    if (a.mind.body.weapon != null) return true;
    if (Common.arm(a, knife)) return true;
    galsia.takeOver(a.tick, a.handle, a.mind.body, @intCast(Common.power(a)), galsia.fights);
    return false;
}

// Rushing in, closing in ----------------------------------------------------------------------------

/// It rushes at its target (a blow that knocks down), its knife in hand, unless it left the
/// screen's middle.
fn jumpInSetUp(a: Actor) void {
    const n = a.numbers();
    if (!Common.chooseTarget(a)) return;
    Common.faceTarget(a);
    a.startMove(.jump_in);
    a.pause(false);
    Common.headForTarget(a, 0, n.jump_in_speed);
    a.mind.passed = false;
    _ = Common.offScreen(a);
}

/// Until past its target across it walks at its speed; then it slows down, and sizes its target
/// up once its speed across is under a pixel a tick.
fn jumpIn(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    if (!armed(a)) return;
    if (!a.mind.passed) {
        const t = Common.target(a) orelse return Common.enter(a, fights);
        const tx = t.position.x.whole();
        const x = e.position.x.whole();
        const past = if (e.velocity.x.raw < 0) tx > x else tx < x;
        if (!past) {
            _ = Common.walk(a);
            return;
        }
        a.mind.passed = true;
        a.pace(n.jump_in_pace, n.jump_in_pace);
    }
    const slowing = if (e.velocity.x.raw < 0) n.jump_in_slowing else n.jump_in_slowing.neg();
    e.velocity.x = e.velocity.x.add(slowing);
    if (@abs(e.velocity.x.raw) >= Fixed.pixels(1).raw) {
        _ = Common.walk(a);
        return;
    }
    a.entity.animation.pace = null;
    a.endMove();
    Common.enter(a, .size_up);
}

/// It closes in to its place beside its target, its knife in hand: there it sizes it up.
fn closeInSetUp(a: Actor) void {
    const n = a.numbers();
    if (!Common.chooseTarget(a)) return;
    a.pause(false);
    Common.faceTarget(a);
    a.animate(.walk_knife);
    a.setTicksLeft(n.close_in_first);
    a.mind.body.speed = n.close_in_speed;
}

fn closeIn(a: Actor) void {
    if (!armed(a)) return;
    if (!Common.pointByOffsets(a)) return;
    if (Common.headForPoint(a)) return Common.enter(a, .size_up);
    _ = Common.walk(a);
}

// Sizing up, stabbing, throwing ----------------------------------------------------------------------

/// It stands a while facing its target; then one that rushed in takes up the fight again; not
/// level with its target it walks off (its place in depth turned over); level, near it stabs and
/// far it throws, unless it left the screen's middle.
fn sizeUpSetUp(a: Actor) void {
    a.mind.body.timer = a.numbers().size_up_ticks;
    a.pause(true);
    Common.faceTarget(a);
}

fn sizeUp(a: Actor) void {
    const n = a.numbers();
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer != 0) return;
    if (a.entity.spawn.entrance == .jump_in) return Common.enter(a, fights);
    const t = Common.target(a) orelse return Common.enter(a, fights);
    const y = a.entity.position.depth.whole();
    const ty = t.position.depth.whole();
    if (ty - n.size_up_level > y + n.size_up_level or ty + n.size_up_level < y - n.size_up_level) {
        a.entity.spawn.offset_depth = -a.entity.spawn.offset_depth;
        return Common.enter(a, .walk_off);
    }
    const near = @abs(a.entity.position.x.whole() - t.position.x.whole()) < n.stab_near;
    if (Common.offScreen(a)) return;
    Common.enter(a, if (near) .stab else .throw);
}

/// The stab: when its reach meets its target, it stabs, and again at its frame while it still
/// does; then it takes up the fight again. Out of reach it walks beside its target, and walks off
/// there.
fn stabSetUp(a: Actor) void {
    a.pause(false);
    a.mind.body.speed = a.numbers().stab_speed;
    a.mind.stabbing = false;
}

fn stab(a: Actor) void {
    const n = a.numbers();
    const reach = a.kind.definition.box("stab_reach").?;
    if (!a.mind.stabbing) {
        if (!Common.boxMeetsTarget(a, reach)) {
            Common.pointBeside(a, n.stab_beside);
            if (Common.headForPoint(a)) return Common.enter(a, .walk_off);
            _ = Common.walk(a);
            return;
        }
        a.mind.stabbing = true;
        Common.faceTarget(a);
        a.startMove(.stab);
        a.pace(n.stab_pace, n.stab_pace);
    }
    if (a.frame() != n.stab_again) return;
    if (Common.boxMeetsTarget(a, reach)) {
        a.setFrame(0);
        return;
    }
    a.endMove();
    a.entity.animation.pace = null;
    Common.enter(a, fights);
}

/// The throw: at its frame the knife leaves its hand (it flies, knife.zig), with its sound; at
/// its last it takes up the fight again, a new knife to take up.
fn throwSetUp(a: Actor) void {
    a.pause(false);
    Common.faceTarget(a);
    a.animate(.throw);
    a.mind.threw = false;
}

fn throw(a: Actor) void {
    const n = a.numbers();
    if (!a.mind.threw and a.frame() == n.throw_frame) {
        a.mind.threw = true;
        if (a.mind.body.weapon) |w| a.tick.throwWeapon(w);
        a.mind.body.weapon = null;
        a.sound(.throw);
    }
    if (a.frame() != n.throw_ends) return;
    Common.enter(a, fights);
}

/// Knocked down: one that rushed in keeps its knife unless the blow took the last of its health
/// (then it lets it fall); any other drops it and is a plain Galsia from now. Whether it became
/// one.
fn knockedDown(a: Actor) bool {
    if (a.entity.spawn.entrance == .jump_in) {
        if (a.entity.health < 0) Common.drop(a);
        return false;
    }
    Common.drop(a);
    a.endMove();
    a.entity.animation.pace = null;
    const h = a.handle;
    const t = a.tick;
    galsia.takeOver(t, h, a.mind.body, @intCast(Common.power(a)), .knocked_down);
    t.begin(h);
    return true;
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

pub fn takeUpBounces(a: Actor, times: u8) void {
    Common.takeUpBounces(a, times);
}

pub fn takeUpStruck(a: Actor, ago: u32, striking: bool) void {
    Common.takeUpStruck(a, ago, striking);
}

pub fn takeUpWeapon(a: Actor, w: Handle) void {
    Common.takeUpWeapon(a, w);
}
