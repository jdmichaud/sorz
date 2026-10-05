//! The acrobat of round 1: out of hiding it takes up the fight the way it was placed (`choose`):
//! it heads for its place beside its target (`approach`) and circles there (`circle`), walking in
//! depth then across, pausing at the place, until its target has changed its course a few times
//! or the pauses run out; then it lines up in depth with its target (`level`) and dashes at it
//! (`dash`), closes in (`close_in`) or, far, jump kicks (`jump_kick`). Closing in, its reach
//! meeting the target it punches (`punch`) and flips back; near, it somersaults at it
//! (`somersault`) and, by a draw, flips back (`flip`), dashes back or takes up the fight. In the
//! air its moves fly across and in height. Its common states are every enemy's (enemy.zig). Its
//! numbers, animations, moves and sounds are its definition's (`entities/acrobat.json`).
//!
//! Not in round 1, and not yet here: its leap or drop in from the screen's edge (`enter`), and its
//! flip away from a knock-down.
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
    circle,
    level,
    punch,
    jump_kick,
    flip,
    somersault,
    close_in,
    dash,
    flip_away,
    approach,
    enter,
};

pub const fights: State = .choose;

pub const countdowns = [_]State{ .approach, .close_in, .stand };

pub const Mind = struct {
    state: State = .appear,
    body: enemy.Body = .{},
    /// The flip goes back; the close in is fast; the dash turns back at once.
    back: bool = false,
    fast: bool = false,
    turned: bool = false,
    /// In the air, down again (a somersault near its target starts down).
    down: bool = false,
    /// Circling: the pauses left, its target's changes of course left, its target's speed across
    /// (whole pixels) as it last saw it.
    stops: u8 = 0,
    turns: u8 = 0,
    seen_speed: i32 = 0,
    /// Knocked down, it has looked whether to flip away.
    looked: bool = false,
};

pub const Animation = enum { walk, down, reel, stand, thrown, slammed, punch, jump_kick, flip };
pub const Move = enum { punch, somersault, jump_kick };
pub const Sound = enum { hurt, thud, cry, cry_odd, leap, land };

pub const Numbers = enemy.Numbers(struct {
    /// Heading for its place: its speed.
    approach_speed: Fixed,
    /// Circling: the ticks it walks in depth only after a pause, the pauses it makes, the
    /// changes of its target's course it waits for, and how near across it flips at its target
    /// when placed to.
    circle_pause: u8,
    circle_stops: u8,
    circle_turns: u8,
    circle_near: i16,
    /// Lining up: its speed in depth; the bits of a draw that, all clear, send it dashing; how
    /// near across it closes in rather than jump kick.
    level_speed: Fixed,
    level_dash_bits: u8,
    level_near: i16,
    /// Closing in: its frames' pace, how long, its speeds (fast after a back flip, slow when
    /// placed so), how far beside its target, and how near it somersaults (in depth, across).
    close_in_pace: u8,
    close_in_ticks: u8,
    close_in_speed: Fixed,
    close_in_fast: Fixed,
    close_in_slow: Fixed,
    close_in_beside: i16,
    close_in_level: i16,
    close_in_near: i16,
    /// The punch ends at this frame.
    punch_ends: u8,
    /// The somersault: its speeds across and up, how near across it starts down, the frame it
    /// ends at.
    somersault_x: Fixed,
    somersault_up: Fixed,
    somersault_near: i16,
    somersault_ends: u8,
    /// The dash: its frames' pace, its speed, how near across it turns back, its ticks back and
    /// its speed in depth then.
    dash_pace: u8,
    dash_speed: Fixed,
    dash_near: i16,
    dash_back_ticks: u8,
    dash_back_depth: Fixed,
    /// The jump kick's speeds up and across; the flip's, and the back flip's (backward).
    jump_kick_up: Fixed,
    jump_kick_x: Fixed,
    flip_up: Fixed,
    flip_x: Fixed,
    back_flip_up: Fixed,
    back_flip_x: Fixed,
    /// The jump kick and the flip hold their frame from these.
    jump_kick_holds: u8,
    flip_holds: u8,
});

pub const Tables = enemy.Tables(struct {});

/// Whether a state takes the players' blows and grabs (a flip does not; a jump kick takes them
/// its own way, `struck`).
pub fn hurtable(state: State) bool {
    return switch (state) {
        .choose, .flip, .flip_away, .enter => false,
        else => true,
    };
}

pub fn begin(a: Actor) void {
    if (looks(a)) return;
    if (!Common.setUpDue(a)) return;
    const was = a.mind.state;
    switch (was) {
        .approach => approachSetUp(a),
        .circle => circleSetUp(a),
        .level => levelSetUp(a),
        .close_in => closeInSetUp(a),
        .punch => punchSetUp(a),
        .somersault => somersaultSetUp(a),
        .dash => dashSetUp(a),
        .jump_kick => jumpKickSetUp(a),
        .flip => flipSetUp(a),
        else => Common.setUp(a),
    }
    _ = Common.leftAt(a, was);
}

pub fn think(a: Actor) void {
    if (!Common.tickStarts(a)) return;
    if (Common.act(a)) return;
    switch (a.mind.state) {
        .choose => choose(a),
        .approach => approach(a),
        .circle => circle(a),
        .level => level(a),
        .close_in => closeIn(a),
        .punch => punch(a),
        .somersault => somersault(a),
        .dash => dash(a),
        .jump_kick => jumpKick(a),
        .flip => flip(a),
        // Not in round 1: they take up the fight at once.
        .enter, .flip_away => Common.enter(a, .approach),
        else => {},
    }
}

/// Knocked down (by a blow, a throw, a new life's knock-back), its first tick it only looks
/// whether to flip away (a trait not in round 1, left for the rounds that place it): it falls
/// from the next, a tick behind the others.
fn looks(a: Actor) bool {
    if (a.mind.state != .knocked_down) {
        a.mind.looked = false;
        return false;
    }
    if (a.mind.looked or a.mind.body.waits) return false;
    a.mind.looked = true;
    Common.setUpOnly(a);
    return true;
}

/// It enters a state with its set-up's flags.
fn go(a: Actor, state: State, flags: struct { back: bool = false, fast: bool = false, turned: bool = false }) void {
    Common.enter(a, state);
    a.mind.back = flags.back;
    a.mind.fast = flags.fast;
    a.mind.turned = flags.turned;
}

/// It takes up the fight the way it was placed.
fn choose(a: Actor) void {
    go(a, switch (a.entity.spawn.entrance) {
        .close_in => .close_in,
        .enter => .enter,
        .circle => .circle,
        else => .approach,
    }, .{});
}

// Approaching and circling ------------------------------------------------------------------------

/// It heads for its place beside its target, facing it: there it circles.
fn approachSetUp(a: Actor) void {
    a.pause(false);
    if (!Common.chooseTarget(a)) return;
    Common.faceTarget(a);
    a.animate(.walk);
    a.setTicksLeft(1);
    a.mind.body.speed = a.numbers().approach_speed;
}

fn approach(a: Actor) void {
    Common.faceTarget(a);
    if (!Common.pointByOffsets(a)) return;
    if (!Common.headForPoint(a)) {
        _ = Common.walk(a);
        return;
    }
    go(a, .circle, .{});
}

/// It circles its place beside its target, facing it: in depth, and across too after a few
/// ticks; at the place it pauses. Its target near across, it flips at it when placed to; its
/// target changing course often enough, or its pauses run out, it lines up.
fn circleSetUp(a: Actor) void {
    const n = a.numbers();
    a.mind.body.timer = n.circle_pause;
    Common.faceTarget(a);
    a.animate(.walk);
    a.mind.seen_speed = if (Common.target(a)) |t| t.velocity.x.whole() else 0;
    a.mind.turns = n.circle_turns;
    a.mind.stops = n.circle_stops;
}

fn circle(a: Actor) void {
    const n = a.numbers();
    const b = &a.mind.body;
    Common.faceTarget(a);
    const t = Common.target(a) orelse return go(a, fights, .{});
    if (a.entity.spawn.traits.flips_at_close_range and @abs(t.position.x.whole() - a.entity.position.x.whole()) < n.circle_near) return go(a, .flip, .{});
    const speed = t.velocity.x.whole();
    if (speed != a.mind.seen_speed) {
        a.mind.turns -%= 1;
        if (a.mind.turns == 0) return go(a, .level, .{});
    }
    a.mind.seen_speed = speed;
    if (!Common.pointByOffsets(a)) return;
    if (Common.headForPoint(a)) {
        a.mind.stops -%= 1;
        if (a.mind.stops == 0) return go(a, .level, .{});
        a.pause(true);
        b.timer = n.circle_pause;
        a.setFrame(1);
        a.setTicksLeft(1);
        return;
    }
    a.pause(false);
    if (!Common.walkDepth(a)) return;
    if (b.timer == 0) {
        _ = Common.walkAcross(a);
        return;
    }
    b.timer -= 1;
}

/// It lines up in depth with its target, facing it; level or past: by a draw it dashes, else
/// near it closes in, far it jump kicks.
fn levelSetUp(a: Actor) void {
    const n = a.numbers();
    if (Common.offScreen(a)) return;
    a.pause(false);
    a.setTicksLeft(1);
    const t = Common.target(a) orelse return;
    a.entity.velocity.depth = if (t.position.depth.whole() >= a.entity.position.depth.whole()) n.level_speed else n.level_speed.neg();
}

fn level(a: Actor) void {
    const n = a.numbers();
    Common.faceTarget(a);
    const t = Common.target(a) orelse return go(a, fights, .{});
    const ty = t.position.depth.whole();
    const y = a.entity.position.depth.whole();
    const past = if (a.entity.velocity.depth.raw < 0) ty >= y else ty < y;
    if (!past) {
        _ = Common.walkDepth(a);
        return;
    }
    if (a.draw(.dash) & n.level_dash_bits == 0) return go(a, .dash, .{});
    go(a, if (@abs(t.position.x.whole() - a.entity.position.x.whole()) < n.level_near) .close_in else .jump_kick, .{});
}

// Closing in, punching, somersaulting, dashing ------------------------------------------------------

/// It closes in beside its target a while: its reach meeting its target it punches; near and
/// level with it, it somersaults; out of time it takes up the fight again.
fn closeInSetUp(a: Actor) void {
    const n = a.numbers();
    a.pause(false);
    Common.faceTarget(a);
    a.animate(.walk);
    a.pace(n.close_in_pace, 1);
    a.setFrame(1);
    a.mind.body.timer = n.close_in_ticks;
}

fn closeIn(a: Actor) void {
    const n = a.numbers();
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer == 0) return go(a, fights, .{});
    var speed = if (a.mind.fast) n.close_in_fast else n.close_in_speed;
    if (a.entity.spawn.traits.slow) speed = n.close_in_slow;
    Common.headForTarget(a, n.close_in_beside, speed);
    if (!Common.walk(a)) return;
    const reach = a.kind.definition.box("close_in_reach") orelse return;
    if (Common.boxMeetsTarget(a, reach)) return go(a, .punch, .{});
    const t = Common.target(a) orelse return;
    if (@abs(a.entity.position.depth.whole() - t.position.depth.whole()) >= n.close_in_level) return;
    if (@abs(a.entity.position.x.whole() - t.position.x.whole()) >= n.close_in_near) return;
    go(a, .somersault, .{});
}

/// The punch, unless it left the screen's middle; at its last frame it flips back.
fn punchSetUp(a: Actor) void {
    if (Common.offScreen(a)) return;
    Common.faceTarget(a);
    a.startMove(.punch);
    a.pause(false);
}

fn punch(a: Actor) void {
    if (a.frame() != a.numbers().punch_ends) return;
    a.endMove();
    go(a, .flip, .{ .back = true });
}

/// The somersault at its target, unless it left the screen's middle: a leap across, held on its
/// first frame until it is down again (at once when near); then, at its last frame, by a draw it
/// flips back, dashes back, or takes up the fight.
fn somersaultSetUp(a: Actor) void {
    const n = a.numbers();
    if (Common.offScreen(a)) return;
    _ = Common.chooseTarget(a);
    a.sound(.leap);
    Common.faceTarget(a);
    a.startMove(.somersault);
    a.pause(true);
    a.setTicksLeft(1);
    a.entity.velocity.x = if (a.entity.facingLeft()) n.somersault_x.neg() else n.somersault_x;
    a.entity.velocity.height = n.somersault_up;
    a.mind.down = false;
    const t = Common.target(a) orelse return;
    if (@abs(t.position.x.whole() - a.entity.position.x.whole()) > n.somersault_near) return;
    a.mind.down = true;
    a.pause(false);
    a.setFrame(1);
}

fn somersault(a: Actor) void {
    const n = a.numbers();
    if (!a.mind.down) {
        Common.flyAcross(a);
        if (!Common.falls(a)) return;
        a.sound(.land);
        a.mind.down = true;
        a.pause(false);
    }
    if (a.frame() != n.somersault_ends) return;
    a.endMove();
    switch (a.draw(.somersault_end) & 3) {
        0 => go(a, .flip, .{ .back = true }),
        1 => go(a, .dash, .{ .turned = true }),
        else => go(a, fights, .{}),
    }
}

/// The dash straight at its target until near across, then back the way it came (its speed
/// across turned, up in depth) a while; then it takes up the fight again. Dashing back after a
/// somersault, it turns at once, which takes that tick.
fn dashSetUp(a: Actor) void {
    const n = a.numbers();
    a.pause(false);
    Common.faceTarget(a);
    a.animate(.walk);
    a.pace(n.dash_pace, 1);
    if (!a.mind.turned) return;
    turnBack(a);
    Common.setUpOnly(a);
}

fn dash(a: Actor) void {
    const n = a.numbers();
    const b = &a.mind.body;
    if (a.mind.turned) {
        if (b.timer == 0) return go(a, fights, .{});
        b.timer -= 1;
        _ = Common.walk(a);
        return;
    }
    Common.headForTarget(a, 0, n.dash_speed);
    if (!Common.walk(a)) return;
    const t = Common.target(a) orelse return;
    if (@abs(t.position.x.whole() - a.entity.position.x.whole()) >= n.dash_near) return;
    a.mind.turned = true;
    turnBack(a);
}

fn turnBack(a: Actor) void {
    const n = a.numbers();
    a.entity.velocity.x = a.entity.velocity.x.neg();
    a.entity.velocity.depth = n.dash_back_depth;
    a.mind.body.timer = n.dash_back_ticks;
}

// Leaps -------------------------------------------------------------------------------------------

/// The jump kick at its target: a leap across, its frame held from its second; down again it
/// takes up the fight. Its blow knocks down.
fn jumpKickSetUp(a: Actor) void {
    const n = a.numbers();
    a.sound(.leap);
    a.pause(false);
    Common.faceTarget(a);
    a.startMove(.jump_kick);
    a.entity.velocity.height = n.jump_kick_up;
    a.entity.velocity.x = if (a.entity.facingLeft()) n.jump_kick_x.neg() else n.jump_kick_x;
}

fn jumpKick(a: Actor) void {
    if (!a.entity.animation.paused and a.frame() == a.numbers().jump_kick_holds) a.pause(true);
    Common.flyAcross(a);
    if (!Common.falls(a)) return;
    a.sound(.land);
    a.endMove();
    go(a, fights, .{});
}

/// The flip toward its target (or the back flip, away from it): a leap, its frame held from its
/// last; down again it closes in.
fn flipSetUp(a: Actor) void {
    const n = a.numbers();
    a.sound(.leap);
    a.pause(false);
    Common.faceTarget(a);
    a.animate(.flip);
    a.entity.velocity.height = if (a.mind.back) n.back_flip_up else n.flip_up;
    const x = if (a.mind.back) n.back_flip_x else n.flip_x;
    a.entity.velocity.x = if (a.entity.facingLeft()) x.neg() else x;
}

fn flip(a: Actor) void {
    const n = a.numbers();
    if (!a.entity.animation.paused and a.frame() == n.flip_holds) a.pause(true);
    Common.flyAcross(a);
    if (!Common.falls(a)) return;
    a.sound(.land);
    a.entity.velocity.height = .zero;
    go(a, .close_in, .{});
}

// The hooks ---------------------------------------------------------------------------------------

/// In a jump kick, a player's blow knocks it down at once, its health spared (a thrown or swung
/// thing's takes its damage); grabs do not hold it.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (a.mind.state != .jump_kick or blow.missile) return Common.struck(a, blow);
    a.endMove();
    a.mind.body.other = blow.attacker;
    Common.enterAtBlow(a, .knocked_down);
    return true;
}

pub fn fall(a: Actor) void {
    Common.fall(a);
}

pub fn landed(a: Actor) void {
    Common.landed(a);
}

pub fn grabbable(a: Actor, by: Handle) bool {
    if (a.mind.state == .jump_kick) return false;
    return Common.grabbable(a, by);
}

pub fn heldBy(a: Actor, holder: Handle) void {
    Common.heldBy(a, holder);
}

pub fn letGoBy(a: Actor, holder: Handle) void {
    Common.letGoBy(a, holder);
}

/// A new life's knock-back knocks it down anew, also when it was down: it looks again.
pub fn knockedBack(a: Actor) void {
    Common.knockedBack(a);
    if (a.mind.state == .knocked_down) a.mind.looked = false;
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

/// Taken up dashing at the speed of a dash back (back across, up in depth), it has turned back
/// since the speed came, its ticks back counted down since.
pub fn takeUpCourse(a: Actor, ago: u32, draws: []const u16) void {
    const n = a.numbers();
    if (a.mind.state == .walk_off) return Common.takeUpCourse(a, ago, draws);
    if (a.mind.state != .dash or a.entity.velocity.depth.raw != n.dash_back_depth.raw) return;
    a.mind.turned = true;
    a.mind.body.fresh = false;
    a.animate(.walk);
    a.pace(n.dash_pace, 1);
    a.mind.body.timer = n.dash_back_ticks -| @as(u8, @intCast(@min(ago, 255)));
}

pub fn takeUpHeld(a: Actor, elapsed: u32) void {
    Common.takeUpHeld(a, elapsed);
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
