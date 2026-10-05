//! The juggler of round 2. Out of hiding it takes up the fight (`choose`) the way the round's
//! script placed it: it heads for its place a way off its target, on its own side (`approach`),
//! juggling two knives (juggler_knife.zig: a maker it leaves makes them, once a juggling begins);
//! there it closes in at a depth by its target's, steps once toward it (`close_in`), then backs
//! off (`lunge`) while its target is near, or sidesteps to its target's depth (`sidestep`) when
//! it is far; level with it, on the screen, it raises its knives (`raise`): when one comes back
//! caught it throws, its knives one after the other from its hand, its throw's frame sending
//! each. Struck or held in these, it stops juggling (its knives fall away as they come back).
//! Its common states (a reel, a knock-down, a hold, its knockout, a stand, a walk off) are every
//! enemy's (enemy.zig). It has no blow of its own. Its numbers, animations and sounds are its
//! definition's (`entities/juggler.json`).
//!
//! TODO(PLAN item 15): its other ways in (keeping away and throwing, leaping and crouching,
//! circling) come with the rounds that place them (4 to 8).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const world_mod = @import("../world.zig");
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
    close_in,
    lunge,
    sidestep,
    raise,
    approach,
};

pub const fights: State = .choose;

pub const countdowns = [_]State{ .approach, .stand };

pub const Mind = struct {
    state: State = .appear,
    body: enemy.Body = .{},
    juggler: Memory = .{},
};

/// What the juggler keeps besides the enemies' body, as the original's bytes.
pub const Memory = struct {
    /// It juggles: its knives are made (a juggling begins only when it does not).
    juggling: bool = false,
    /// A byte its close in and its raise share: the close in's first arrival (bit 0), the
    /// raise's wait for a knife caught.
    shared: u8 = 0,
    /// Raising: the throws left; it holds its throw's pose (a knife caught); its first knife
    /// came back (and was tossed up), one came back caught, one is in its hand. Its knives set
    /// these; entering the raise clears them.
    throws: u8 = 0,
    posing: bool = false,
    tossed_first: bool = false,
    caught: bool = false,
    in_hand: bool = false,
};

pub const Animation = enum { walk, down, reel, stand, thrown, slammed, throw };
pub const Sound = enum { hurt, thud, cry, cry_odd };

pub const Numbers = enemy.Numbers(struct {
    /// Approaching: its speed, how far from its target on its own side, its ticks, its walk's
    /// first frame's ticks.
    approach_speed: Fixed,
    approach_beside: i16,
    approach_ticks: u8,
    approach_first: u8,
    /// Closing in: the depth it walks to, near when its target's depth is below `close_level`,
    /// else far; the step toward its target once there.
    close_level: i16,
    close_near: i16,
    close_far: i16,
    close_step: i16,
    /// The lunge: its target farther across than `lunge_far`, it sidesteps; than `lunge_near`,
    /// it takes up the fight again; else it backs off `lunge_step` at `lunge_speed`.
    lunge_far: i16,
    lunge_near: i16,
    lunge_speed: Fixed,
    lunge_step: i16,
    /// The sidestep's speeds, and the depth within which its target is level with it.
    sidestep_x: Fixed,
    sidestep_depth: Fixed,
    sidestep_level: i16,
    /// The raise: its frames' pace, its throws, its wait for a knife in hand and for a knife
    /// caught; the frame of its throw that sends a knife.
    raise_pace: u8,
    raise_throws: u8,
    raise_ticks: u8,
    raise_wait: u8,
    throw_frame: u8,
});

pub const Tables = enemy.Tables(struct {});

/// The kind of its knives.
pub const knife_kind = "juggler_knife";

pub fn hurtable(state: State) bool {
    return switch (state) {
        .choose => false,
        else => true,
    };
}

pub fn begin(a: Actor) void {
    // Knocked down, however, it stops juggling (the original's way into the knock-down).
    if (a.mind.state == .knocked_down) a.mind.juggler.juggling = false;
    if (!Common.setUpDue(a)) return;
    const was = a.mind.state;
    switch (was) {
        .approach => approachSetUp(a),
        .close_in => closeInSetUp(a),
        .lunge => lungeSetUp(a),
        .sidestep => sidestepSetUp(a),
        .raise => raiseSetUp(a),
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
        .approach => approach(a),
        .close_in => closeIn(a),
        .lunge => lunge(a),
        .sidestep => sidestep(a),
        .raise => raise(a),
        else => {},
    }
}

/// It takes up the fight the way it was placed.
fn choose(a: Actor) void {
    if (!Common.chooseTarget(a)) return;
    enter(a, .approach);
}

/// Enters `state`: a raise starts with its knives' marks cleared (the original's state word
/// clears them).
fn enter(a: Actor, state: State) void {
    const m = &a.mind.juggler;
    if (state == .raise) {
        m.posing = false;
        m.tossed_first = false;
        m.caught = false;
        m.in_hand = false;
    }
    Common.enter(a, state);
}

/// It stops juggling and takes up the fight again.
fn endJuggling(a: Actor) void {
    a.mind.juggler.juggling = false;
    enter(a, .choose);
}

// Its knives ---------------------------------------------------------------------------------

/// Its knives' maker, in the first of the enemies' free places (none: none, its juggling
/// begun all the same, as the original's); a new object of the original's, at no place.
fn makeKnives(a: Actor) void {
    const kind = a.tick.kinds.find(knife_kind) orelse return;
    const places = world_mod.World.enemy_places;
    const h = a.tick.world.spawnWithin(a.tick.kinds, kind, places.from, places.to, .zero, .right) catch return;
    const k = a.tick.world.get(h).?;
    // Unseen, never left behind (the original culls none of them), from its making on: a place
    // before its maker's takes its first turn at the next tick.
    k.flags.still = true;
    k.flags.hidden = true;
    k.flags.stays = true;
    k.mind.juggler_knife.state = .maker;
    k.mind.juggler_knife.holder = a.handle;
}

// Approaching, closing in -------------------------------------------------------------------

/// It heads for its place `approach_beside` from its target on its own side, at its depth,
/// juggling (its knives made when it was not), for a while; out of the screen's middle, it
/// walks off.
fn approachSetUp(a: Actor) void {
    const n = a.numbers();
    const b = &a.mind.body;
    if (!Common.chooseTarget(a)) return;
    if (!a.mind.juggler.juggling) {
        a.mind.juggler.juggling = true;
        makeKnives(a);
    }
    if (Common.offScreen(a)) return;
    Common.faceTarget(a);
    a.animate(.walk);
    a.pause(false);
    a.setTicksLeft(n.approach_first);
    if (!Common.chooseTarget(a)) return;
    const t = Common.target(a) orelse return;
    const tx = t.position.x.whole();
    const beside: i32 = if (a.entity.position.x.whole() > tx) n.approach_beside else -@as(i32, n.approach_beside);
    b.dest_x = .pixels(tx + beside);
    b.dest_depth = .pixels(t.position.depth.whole());
    b.speed = n.approach_speed;
    b.timer = n.approach_ticks;
}

fn approach(a: Actor) void {
    const b = &a.mind.body;
    b.timer -%= 1;
    if (b.timer == 0) return enter(a, .choose);
    if (Common.headForPoint(a)) return enter(a, .close_in);
    _ = Common.walk(a);
}

/// It closes in to the depth by its target's (near or far); there it steps once toward its
/// target, then lunges.
fn closeInSetUp(a: Actor) void {
    const n = a.numbers();
    const t = Common.target(a) orelse return;
    a.mind.body.dest_depth = .pixels(if (t.position.depth.whole() > n.close_level) n.close_near else n.close_far);
}

fn closeIn(a: Actor) void {
    const n = a.numbers();
    const m = &a.mind.juggler;
    if (!Common.headForPoint(a)) {
        _ = Common.walk(a);
        return;
    }
    if (m.shared & 1 != 0) {
        m.shared = 0;
        return enter(a, .lunge);
    }
    m.shared |= 1;
    const t = Common.target(a) orelse return;
    const step: i32 = if (t.position.x.whole() > a.entity.position.x.whole()) n.close_step else -@as(i32, n.close_step);
    a.mind.body.dest_x = a.mind.body.dest_x.add(.pixels(step));
}

// The lunge, the sidestep ------------------------------------------------------------------------

/// Off the screen's middle it walks off; its target far, it sidesteps; not near, it takes up the
/// fight again; near, it backs off a step, quick, and lunges again.
fn lungeSetUp(a: Actor) void {
    const n = a.numbers();
    if (Common.offScreen(a)) return;
    const t = Common.target(a) orelse return;
    const x = a.entity.position.x.whole();
    const across = @abs(x - t.position.x.whole());
    if (across > n.lunge_far) return enter(a, .sidestep);
    if (across > n.lunge_near) return enter(a, .choose);
    a.mind.body.speed = n.lunge_speed;
    const step: i32 = if (x > t.position.x.whole()) n.lunge_step else -@as(i32, n.lunge_step);
    a.mind.body.dest_x = a.mind.body.dest_x.add(.pixels(step));
}

fn lunge(a: Actor) void {
    if (!Common.headForPoint(a)) {
        _ = Common.walk(a);
        return;
    }
    enter(a, .lunge);
}

/// Away from its target across and toward its depth, until level with it; then, on the screen,
/// it raises its knives, else it walks off.
fn sidestepSetUp(a: Actor) void {
    const n = a.numbers();
    const t = Common.target(a) orelse return;
    const e = a.entity;
    e.velocity.x = if (t.position.x.whole() < e.position.x.whole()) n.sidestep_x else n.sidestep_x.neg();
    e.velocity.depth = if (t.position.depth.whole() > e.position.depth.whole()) n.sidestep_depth else n.sidestep_depth.neg();
}

fn sidestep(a: Actor) void {
    const n = a.numbers();
    const t = Common.target(a) orelse return;
    if (@abs(t.position.depth.whole() - a.entity.position.depth.whole()) > n.sidestep_level) {
        _ = Common.walk(a);
        return;
    }
    if (Common.inMiddle(a)) enter(a, .raise) else Common.enter(a, .walk_off);
}

// The raise -------------------------------------------------------------------------------------

/// It juggles in place, its walk paced, waiting for a knife to come back caught; then it holds
/// its throw's first pose facing its target, and each knife put in its hand sends its throw's
/// frames on: at its throw's frame the knife leaves, and it holds the pose again for the next.
/// Its throws done, or no knife coming, it stops juggling and takes up the fight again.
fn raiseSetUp(a: Actor) void {
    const n = a.numbers();
    const m = &a.mind.juggler;
    a.pause(false);
    a.pace(n.raise_pace, n.raise_pace);
    m.throws = n.raise_throws;
    a.mind.body.timer = n.raise_ticks;
    m.shared = n.raise_wait;
}

fn raise(a: Actor) void {
    const n = a.numbers();
    const m = &a.mind.juggler;
    if (!m.posing) {
        m.shared -%= 1;
        if (m.shared == 0) return endJuggling(a);
        if (!m.caught) return;
        m.posing = true;
        Common.faceTarget(a);
        a.animate(.throw);
        a.pause(true);
    }
    if (m.in_hand) {
        a.pause(false);
        if (a.frame() != n.throw_frame) return;
        m.throws -%= 1;
        if (m.throws == 0) return endJuggling(a);
        m.in_hand = false;
        a.setFrame(0);
        a.pause(true);
        return;
    }
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer == 0) endJuggling(a);
}

// The hooks ---------------------------------------------------------------------------------------

/// The states whose test of the blows and the grabs stops its juggling when one takes it (the
/// original's own test, in its ways' states); its walk off's, at a blow.
fn stopsJuggling(state: State) bool {
    return switch (state) {
        .approach, .close_in, .lunge, .sidestep, .raise => true,
        else => false,
    };
}

/// A blow it takes in its ways' states or its walk off, or one that knocks it down, stops its
/// juggling.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    const was = a.mind.state;
    if (!Common.struck(a, blow)) return false;
    if (stopsJuggling(was) or was == .walk_off or a.mind.state == .knocked_down) a.mind.juggler.juggling = false;
    return true;
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

/// Held in its ways' states, it stops juggling.
pub fn heldBy(a: Actor, holder: Handle) void {
    if (stopsJuggling(a.mind.state)) a.mind.juggler.juggling = false;
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

pub fn takeUp(a: Actor, elapsed: u32) void {
    Common.takeUp(a, elapsed);
}

pub fn takeUpHeld(a: Actor, elapsed: u32) void {
    Common.takeUpHeld(a, elapsed);
}
