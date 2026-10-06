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
//! Placed so (round 5), knocked down with health left it looks at its first tick: on an odd tick
//! it falls at once, on an even one it flips away from the one who struck it (`flip_away`), up
//! and away, turning to its target in the air; down again it crouches a while, then jump kicks or
//! closes in fast.
//!
//! Placed so (round 5), it comes in leaping from behind the wall (`enter`): hidden once out,
//! below its place in depth 0, it waits until the camera nears it; then it rises in its flip's
//! pose, drawn in front from its top, and comes down deeper each tick to the ground, where it
//! closes in, from then on placed as a plain acrobat. Placed to drop in instead, it falls from
//! above at a drawn place.
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
    /// Coming in: the camera has neared it; it has passed its top.
    reached: bool = false,
    risen: bool = false,
    /// Its jump kick closes in after it lands (a trio's: acrobat_trio.zig), not the fight's
    /// start.
    close_in_after: bool = false,
};

/// The state a somersault's end may dash back in (the original's state 15).
pub const somersault_back: ?State = .dash;

const Attack = Attacks(@This());

pub const Animation = enum { walk, down, reel, stand, thrown, slammed, punch, jump_kick, flip, turn };
pub const Move = enum { punch, somersault, jump_kick };
pub const Sound = enum { hurt, thud, cry, cry_odd, leap, land, flip_away };

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
    /// The flip away: its speeds across (away from the one who struck it) and up (whole pixels),
    /// its frames' pace, its frame it turns to its target at; down, its crouch's frame and ticks.
    flip_away_x: i16,
    flip_away_up: i16,
    flip_away_pace: u8,
    flip_away_turns: u8,
    flip_away_crouch: u8,
    flip_away_ticks: u8,
    /// Coming in: how far below its place it waits, its speed up and its gravity; how near
    /// the camera's place it waits (twice that unless `slow`), its frame from then; how much
    /// deeper it comes each tick down. Dropping in: its height, its place across (a draw's low
    /// bits added), its depth.
    enter_below: i16,
    enter_up: i16,
    enter_gravity: Fixed,
    enter_near: i16,
    enter_frame: u8,
    enter_deeper: i16,
    drop_height: i16,
    drop_x: i16,
    drop_spread: u16,
    drop_depth: i16,
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
        .close_in => Attack.closeInSetUp(a),
        .punch => Attack.punchSetUp(a),
        .somersault => Attack.somersaultSetUp(a),
        .dash => dashSetUp(a),
        .jump_kick => Attack.jumpKickSetUp(a),
        .flip => Attack.flipSetUp(a),
        .flip_away => flipAwaySetUp(a),
        .enter => enterSetUp(a),
        else => Common.setUp(a),
    }
    _ = Common.leftAt(a, was);
}

pub fn think(a: Actor) void {
    defer Common.endTick(a);
    if (!Common.tickStarts(a)) return;
    if (Common.act(a)) {
        // Placed to come in leaping, it stays hidden once out, until its leap begins.
        if (a.mind.state == fights and a.entity.spawn.entrance == .enter) a.entity.flags.hidden = true;
        return;
    }
    switch (a.mind.state) {
        .choose => choose(a),
        .approach => approach(a),
        .circle => circle(a),
        .level => level(a),
        .close_in => Attack.closeIn(a),
        .punch => Attack.punch(a),
        .somersault => Attack.somersault(a),
        .dash => dash(a),
        .jump_kick => Attack.jumpKick(a),
        .flip => Attack.flip(a),
        .flip_away => flipAway(a),
        .enter => enter(a),
        else => {},
    }
}

/// Knocked down (by a blow, a throw, a new life's knock-back), its first tick it only looks
/// whether to flip away: it falls from the next, a tick behind the others; but placed to flip
/// away, with health left, on an odd tick it falls at once, on an even one it flips away from
/// the next. Flipped over its holder, it looks at no flip away.
fn looks(a: Actor) bool {
    if (a.mind.state != .knocked_down) {
        a.mind.looked = false;
        return false;
    }
    if (a.mind.looked or a.mind.body.waits) return false;
    a.mind.looked = true;
    const flipped = a.mind.body.flipped;
    a.mind.body.flipped = false;
    if (!flipped and a.entity.health >= 0 and a.entity.spawn.traits.flips_away) {
        if (a.tick.world.tick & 1 != 0) return false;
        go(a, .flip_away, .{});
    }
    Common.setUpOnly(a);
    return true;
}

fn go(a: Actor, state: State, flags: Attack.Flags) void {
    Attack.next(a, state, flags);
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

// Dashing ---------------------------------------------------------------------------------------

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

// Coming in, flipping away -------------------------------------------------------------------------

/// Its leap in: shown, behind the wall, in depth 0 and `enter_below` lower, facing its target
/// in its flip's first pose, its speed up `enter_up` (whole pixels, the fractions kept). Placed
/// to drop in: from `drop_height` at a drawn place across, at `drop_depth`, still.
fn enterSetUp(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    e.flags.hidden = false;
    e.flags.in_front = false;
    e.position.depth = .parts(0, e.position.depth.frac());
    e.velocity.height = .parts(n.enter_up, e.velocity.height.frac());
    Common.faceTarget(a);
    a.animate(.flip);
    e.position.height = e.position.height.add(.pixels(n.enter_below));
    a.mind.reached = false;
    a.mind.risen = false;
    if (!e.spawn.traits.drops_in) return;
    // Its first pose held all the way down: the original's frames do not run there.
    a.pause(true);
    e.position.height = .parts(n.drop_height, e.position.height.frac());
    e.velocity.height = .parts(0, e.velocity.height.frac());
    const x: i32 = @as(i32, a.draw(.drop_place) & n.drop_spread) + n.drop_x;
    e.position.x = .parts(@intCast(x), e.position.x.frac());
    e.position.depth = .parts(n.drop_depth, e.position.depth.frac());
}

/// It waits until the camera's place is within `enter_near` of its own (twice that unless
/// `slow`); then in its flip's frame `enter_frame` facing its target it rises, its frames
/// running; at its top it is drawn in front (its frames held when at that frame); down, deeper
/// each tick, until it lands: then it closes in, a plain acrobat.
fn enter(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    if (!e.spawn.traits.drops_in) {
        if (!a.mind.reached) {
            var near: i32 = a.tick.world.camera.x.whole() + n.enter_near;
            if (!e.spawn.traits.slow) near += n.enter_near;
            if (near < e.position.x.whole()) return;
            a.mind.reached = true;
            a.setFrame(n.enter_frame);
            Common.faceTarget(a);
        }
        if (a.mind.risen or e.velocity.height.raw < 0) return enterFlight(a);
        a.mind.risen = true;
        a.pause(false);
        e.flags.in_front = true;
    }
    if (!e.animation.paused and a.frame() == n.enter_frame) a.pause(true);
    enterFlight(a);
}

/// Its leap's flight: its gravity, its height; coming down, deeper each tick, and on the ground
/// it lands (its height's fraction kept), placed from then as a plain acrobat, and closes in.
fn enterFlight(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    e.velocity.height = e.velocity.height.add(n.enter_gravity);
    e.position.height = e.position.height.add(e.velocity.height);
    if (e.velocity.height.raw < 0) return;
    e.position.depth = e.position.depth.add(.pixels(n.enter_deeper));
    if (!a.atGround()) return;
    e.position.height = .parts(@intCast(a.tick.world.ground.whole()), e.position.height.frac());
    a.sound(.land);
    e.spawn = .{ .offset_x = e.spawn.offset_x, .offset_depth = e.spawn.offset_depth, .strength = e.spawn.strength, .colours = e.spawn.colours, .art = e.spawn.art };
    e.velocity.height = .zero;
    go(a, .close_in, .{});
}

/// The flip away from the one who struck it, facing it in its knock-down's pose, up and away
/// across (whole pixels, the fractions kept), its frames paced.
fn flipAwaySetUp(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    a.sound(.flip_away);
    const x: i16 = if (Common.faceStriker(a)) n.flip_away_x else -n.flip_away_x;
    e.velocity.x = .parts(x, e.velocity.x.frac());
    e.velocity.height = .parts(n.flip_away_up, e.velocity.height.frac());
    a.animate(.down);
    a.pause(false);
    a.pace(n.flip_away_pace, n.flip_away_pace);
    a.mind.turned = false;
    a.mind.down = false;
}

/// In the air, at its frame `flip_away_turns` it turns to its target (its turn's pose); down
/// again it crouches a while in its knock-down's frame, then jump kicks, or on an odd tick
/// closes in fast.
fn flipAway(a: Actor) void {
    const n = a.numbers();
    if (!a.mind.down) {
        if (!a.mind.turned and a.frame() == n.flip_away_turns) {
            a.mind.turned = true;
            Common.faceTarget(a);
            a.animate(.turn);
        }
        Common.flyAcross(a);
        if (!Common.falls(a)) return;
        a.mind.down = true;
        Common.faceTarget(a);
        a.animate(.down);
        a.setFrame(n.flip_away_crouch);
        a.pause(true);
        a.mind.body.timer = n.flip_away_ticks;
    }
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer != 0) return;
    if (a.tick.world.tick & 1 != 0) return go(a, .close_in, .{ .fast = true });
    go(a, .jump_kick, .{});
}

// The hooks ---------------------------------------------------------------------------------------

pub fn struck(a: Actor, blow: tick.Blow) bool {
    return Attack.struck(a, blow);
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
    return Attack.grabbable(a, by);
}

pub fn heldBy(a: Actor, holder: Handle) void {
    Common.heldBy(a, holder);
}

pub fn letGoBy(a: Actor, holder: Handle) void {
    Common.letGoBy(a, holder);
}

/// A new life's knock-back knocks it down anew, also when it was down: it looks again.
/// Brought back at a wall (enemy.zig's `leftBehind`).
pub fn leftBehind(a: Actor) void {
    Common.leftBehind(a);
}

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

/// The acrobat's attacks, for module `M` (the acrobat's, the trio's: acrobat_trio.zig): its
/// close in, punch, somersault, jump kick and flip, by its definition's numbers (the acrobat's).
/// `M` declares the states `close_in`, `punch`, `somersault`, `jump_kick`, `flip` (numbered as
/// the acrobat's), `fights`, and `somersault_back` (the state a somersault's end may dash back
/// in: the acrobat's dash; none for the trio, which takes up the fight then); its `Mind` the
/// acrobat's flags (`back`, `fast`,
/// `turned`, `down`, `close_in_after`).
pub fn Attacks(comptime M: type) type {
    return struct {
        const A = tick.Actor(M);
        const C = enemy.Of(M);

        pub const Flags = struct { back: bool = false, fast: bool = false, turned: bool = false };

        /// It enters a state with its set-up's flags.
        pub fn next(a: A, state: M.State, flags: Flags) void {
            C.enter(a, state);
            a.mind.back = flags.back;
            a.mind.fast = flags.fast;
            a.mind.turned = flags.turned;
        }

        /// It closes in beside its target a while: its reach meeting its target it punches; near
        /// and level with it, it somersaults; out of time it takes up the fight again.
        pub fn closeInSetUp(a: A) void {
            const n = a.numbers();
            a.pause(false);
            C.faceTarget(a);
            a.animate(.walk);
            a.pace(n.close_in_pace, 1);
            a.setFrame(1);
            a.mind.body.timer = n.close_in_ticks;
        }

        pub fn closeIn(a: A) void {
            const n = a.numbers();
            a.mind.body.timer -%= 1;
            if (a.mind.body.timer == 0) return next(a, M.fights, .{});
            var speed = if (a.mind.fast) n.close_in_fast else n.close_in_speed;
            if (a.entity.spawn.traits.slow) speed = n.close_in_slow;
            C.headForTarget(a, n.close_in_beside, speed);
            if (!C.walk(a)) return;
            const reach = a.kind.definition.box("close_in_reach") orelse return;
            if (C.boxMeetsTarget(a, reach)) return next(a, .punch, .{});
            const t = C.target(a) orelse return;
            if (@abs(a.entity.position.depth.whole() - t.position.depth.whole()) >= n.close_in_level) return;
            if (@abs(a.entity.position.x.whole() - t.position.x.whole()) >= n.close_in_near) return;
            next(a, .somersault, .{});
        }

        /// The punch, unless it left the screen's middle; at its last frame it flips back.
        pub fn punchSetUp(a: A) void {
            if (C.offScreen(a)) return;
            C.faceTarget(a);
            a.startMove(.punch);
            a.pause(false);
        }

        pub fn punch(a: A) void {
            if (a.frame() != a.numbers().punch_ends) return;
            a.endMove();
            next(a, .flip, .{ .back = true });
        }

        /// The somersault at its target, unless it left the screen's middle: a leap across, held
        /// on its first frame until it is down again (at once when near); then, at its last
        /// frame, by a draw it flips back, dashes back (`somersault_back`), or takes up the fight.
        pub fn somersaultSetUp(a: A) void {
            const n = a.numbers();
            if (C.offScreen(a)) return;
            _ = C.chooseTarget(a);
            a.sound(.leap);
            C.faceTarget(a);
            a.startMove(.somersault);
            a.pause(true);
            a.setTicksLeft(1);
            a.entity.velocity.x = if (a.entity.facingLeft()) n.somersault_x.neg() else n.somersault_x;
            a.entity.velocity.height = n.somersault_up;
            a.mind.down = false;
            const t = C.target(a) orelse return;
            if (@abs(t.position.x.whole() - a.entity.position.x.whole()) > n.somersault_near) return;
            a.mind.down = true;
            a.pause(false);
            a.setFrame(1);
        }

        pub fn somersault(a: A) void {
            const n = a.numbers();
            if (!a.mind.down) {
                C.flyAcross(a);
                if (!C.falls(a)) return;
                a.sound(.land);
                a.mind.down = true;
                a.pause(false);
            }
            if (a.frame() != n.somersault_ends) return;
            a.endMove();
            switch (a.draw(.somersault_end) & 3) {
                0 => next(a, .flip, .{ .back = true }),
                1 => if (M.somersault_back) |back| next(a, back, .{ .turned = true }) else next(a, M.fights, .{}),
                else => next(a, M.fights, .{}),
            }
        }

        /// The jump kick at its target: a leap across, its frame held from its second; down
        /// again it takes up the fight (or closes in, `close_in_after`). Its blow knocks down.
        pub fn jumpKickSetUp(a: A) void {
            const n = a.numbers();
            a.sound(.leap);
            a.pause(false);
            C.faceTarget(a);
            a.startMove(.jump_kick);
            a.entity.velocity.height = n.jump_kick_up;
            a.entity.velocity.x = if (a.entity.facingLeft()) n.jump_kick_x.neg() else n.jump_kick_x;
        }

        pub fn jumpKick(a: A) void {
            if (!a.entity.animation.paused and a.frame() == a.numbers().jump_kick_holds) a.pause(true);
            C.flyAcross(a);
            if (!C.falls(a)) return;
            a.sound(.land);
            a.endMove();
            const after = a.mind.close_in_after;
            a.mind.close_in_after = false;
            next(a, if (after) .close_in else M.fights, .{});
        }

        /// The flip toward its target (or the back flip, away from it): a leap, its frame held
        /// from its last; down again it closes in.
        pub fn flipSetUp(a: A) void {
            const n = a.numbers();
            a.sound(.leap);
            a.pause(false);
            C.faceTarget(a);
            a.animate(.flip);
            a.entity.velocity.height = if (a.mind.back) n.back_flip_up else n.flip_up;
            const x = if (a.mind.back) n.back_flip_x else n.flip_x;
            a.entity.velocity.x = if (a.entity.facingLeft()) x.neg() else x;
        }

        pub fn flip(a: A) void {
            const n = a.numbers();
            if (!a.entity.animation.paused and a.frame() == n.flip_holds) a.pause(true);
            C.flyAcross(a);
            if (!C.falls(a)) return;
            a.sound(.land);
            a.entity.velocity.height = .zero;
            next(a, .close_in, .{});
        }

        /// In a jump kick, a player's blow knocks it down at once, its health spared (a thrown
        /// or swung thing's takes its damage); grabs do not hold it.
        pub fn struck(a: A, blow: tick.Blow) bool {
            if (a.mind.state != .jump_kick or blow.missile) return C.struck(a, blow);
            a.endMove();
            a.mind.body.other = blow.attacker;
            C.enterAtBlow(a, .knocked_down);
            return true;
        }

        pub fn grabbable(a: A, by: Handle) bool {
            if (a.mind.state == .jump_kick) return false;
            return C.grabbable(a, by);
        }
    };
}
