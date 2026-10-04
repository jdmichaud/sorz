//! A Galsia, the street punk of round 1, as the first wave's: it waits hidden until it comes on
//! the screen, closes in beside the player and punches when its reach meets the player's body;
//! it reels from a blow, is knocked down (it flies back, bounces twice, lies a while and gets
//! up), knocked out when its health is gone; a player grabs and holds it, knees it, throws it,
//! slams it down. Its numbers, animations, punch and sounds are its definition's
//! (`entities/galsia.json`). The other ways a Galsia approaches (circling, waiting at the screen's
//! edge, the shutters) and its walks off are PLAN item 12's.
//!
//! Each state sets itself up at its first tick, the tick after it was entered, before the blows
//! of that tick (`begin`), as the original's enemies do; the blows and grabs of a tick come
//! before the rest of its tick (`think`, systems.zig), where it stood. It applies its gravity
//! before it moves, as the original's objects do.
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const content_entity = @import("../../content/entity.zig");
const systems = @import("../systems.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

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
    punch,
};

/// How a knock-down goes on: flying (and bouncing), sliding after a throw, lying.
pub const Down = enum { flying, sliding, lying };

pub const Mind = struct {
    state: State = .appear,
    /// The state's set-up is due (its first tick).
    fresh: bool = true,
    /// It entered its state at this tick's blows or grabs (or another's tick), before its own
    /// tick: its first tick is the next. The world's tick of its last tick.
    waits: bool = false,
    thought: u32 = std.math.maxInt(u32),
    timer: u8 = 0,
    /// The player it goes after, and the one whose blow or hold it took last.
    target: ?Handle = null,
    other: ?Handle = null,
    /// The point it walks to.
    dest_x: Fixed = .zero,
    dest_depth: Fixed = .zero,
    /// The reel: its first tick (the blow taken then), a blow that knocks down, a blow touching
    /// it at this tick, and the touch going on already taken (it is not taken again until a tick
    /// without a touch).
    reel_taken: bool = false,
    finishing: bool = false,
    touched: bool = false,
    touch_taken: bool = false,
    /// A third blow of the combo settles the reel at its pose, at the tick after the next.
    settling: bool = false,
    settle_wait: bool = false,
    /// The punch's last blow was tested once.
    tested: bool = false,
    /// Knocked down: how it goes on, its bounces, its flight slowing.
    down: Down = .flying,
    bounces: u8 = 0,
    slowing: bool = false,
    /// Held: the holder's move it last took a blow from, a slam's ticks under way.
    hold_move: ?u8 = null,
    slam: u8 = 0,
    /// Knocked out: the blinks left.
    blinks: u8 = 0,
    /// The walk off: it paces across (after its walk away in depth), on the right of its target
    /// when it began; its walks off one soon after the other, and the tick of the last.
    /// It cried its knockout.
    cried: bool = false,
    /// Held still by the special attack: its pose (by its place across when the attack came),
    /// and the ticks to its next turn about.
    special_pose: u2 = 0,
    pacing: bool = false,
    right_side: bool = false,
    retreats: u8 = 0,
    last_walk_off: u32 = 0,
};

pub const Animation = enum { walk, down, reel, stand, thrown, punch, slammed };
pub const Move = enum { punch, punch_last };
pub const Sound = enum { hurt, thud, cry, cry_odd };

pub const Numbers = struct {
    reach_frame: u8,
    last_punch_frame: u8,
    last_punch_test: u8,
    punch_ends: u8,
    /// It comes out of hiding with its place this far from the view's left edge.
    appears_from: i16,
    appears_to: i16,
    close_in_speed: Fixed,
    close_in_ticks: u8,
    close_in_beside: i16,
    close_in_pace: u8,
    reel: u8,
    reel_nudge: i16,
    knocked_x: Fixed,
    knocked_out_x: Fixed,
    knocked_up: Fixed,
    knocked_slowing: Fixed,
    bounce_most: Fixed,
    bounce_slowing: Fixed,
    lying: u8,
    lying_least: u8,
    gets_up_frame: u8,
    fall_most: Fixed,
    blinks: u8,
    first_blink: u8,
    blink: u8,
    struck_held: u8,
    flipped_x: Fixed,
    flipped_up: Fixed,
    thrown_x: Fixed,
    thrown_up: Fixed,
    thrown_slide: u8,
    slam_ticks: u8,
    slammed_x: Fixed,
    slammed_up: Fixed,
    grab_height: i16,
    special_spin_frame: u8,
    special_spin_turn: u8,
    special_down_frame: u8,
    special_shake_pace: u8,
    special_shake_turn: u8,
    walk_off_pace: u8,
    walk_off_depth: Fixed,
    walk_off_faster: Fixed,
    walk_off_fastest: Fixed,
    walk_off_faster_after: u8,
    walk_off_fastest_after: u8,
    walk_off_up_from: i16,
    walk_off_down_to: i16,
    walk_off_up_to: i16,
    walk_off_again: u8,
    walk_off_near: i16,
    pacing_0: u8,
    pacing_1: u8,
    pacing_2: u8,
    pacing_3: u8,
    pacing_speed_0: Fixed,
    pacing_speed_1: Fixed,
    pacing_speed_2: Fixed,
    pacing_speed_3: Fixed,
    pacing_pace_0: u8,
    pacing_pace_1: u8,
    pacing_pace_2: u8,
    pacing_pace_3: u8,
};

/// Enters `state`; it sets itself up at its next tick.
fn enter(a: Actor, state: State) void {
    a.mind.state = state;
    a.mind.fresh = true;
}

/// Enters `state` at a blow or a grab of this tick, which come before its tick: it begins at the
/// next, as the original's enemies, which take their blows at the start of their tick and leave
/// it there.
fn enterAtBlow(a: Actor, state: State) void {
    enter(a, state);
    a.mind.waits = a.mind.thought != a.tick.world.tick;
}

/// The state it entered at the last tick sets itself up, before the blows of this tick.
pub fn begin(a: Actor) void {
    if (a.mind.waits or !a.mind.fresh) return;
    a.mind.fresh = false;
    switch (a.mind.state) {
        .close_in => closeInSetUp(a),
        .punch => punchSetUp(a),
        .knocked_down => knockedDownSetUp(a),
        .knocked_out => knockedOutSetUp(a),
        .stand => standSetUp(a),
        .walk_off => walkOffSetUp(a),
        else => {},
    }
}

pub fn think(a: Actor) void {
    a.mind.thought = a.tick.world.tick;
    if (!a.mind.touched) a.mind.touch_taken = false;
    a.mind.touched = false;
    // It moves only where its state walks or flies (`go`), its speed kept otherwise.
    a.entity.flags.still = true;
    if (a.mind.waits) {
        a.mind.waits = false;
        return;
    }
    a.mind.fresh = false;
    switch (a.mind.state) {
        .appear => appear(a),
        .choose => {
            a.mind.target = a.nearest(.player);
            if (a.mind.target == null) return enter(a, .stand);
            enter(a, .close_in);
        },
        .close_in => closeIn(a),
        .punch => punch(a),
        .reel => reel(a),
        .knocked_down => knockedDown(a),
        .knocked_out => knockedOut(a),
        .held => held(a),
        .stand => standing(a),
        .walk_off => walkOff(a),
    }
}

/// Hidden until its place comes on the screen; then its health, its walk, and it chooses.
fn appear(a: Actor) void {
    const n = a.numbers();
    a.entity.flags.hidden = true;
    const on_screen = a.entity.position.x.sub(a.tick.world.camera.x).whole();
    if (on_screen < n.appears_from or on_screen > n.appears_to) return;
    a.entity.flags.hidden = false;
    a.entity.health = a.kind.definition.health;
    a.animate(.walk);
    a.mind.target = a.nearest(.player);
    enter(a, .choose);
}

/// It moves by its speed at this tick.
fn go(a: Actor) void {
    a.entity.flags.still = false;
}

fn target(a: Actor) ?*entity.Entity {
    const h = a.mind.target orelse return null;
    return a.other(h);
}

/// It closes in to a point beside its target, at its depth, for a while: there, out of reach,
/// it walks off; its reach meeting the target's body, it punches.
fn closeInSetUp(a: Actor) void {
    const n = a.numbers();
    const t = target(a) orelse return;
    a.faceToward(t);
    a.animate(.walk);
    a.pause(false);
    a.pace(n.close_in_pace, 1);
    a.mind.timer = n.close_in_ticks;
}

fn closeIn(a: Actor) void {
    const n = a.numbers();
    const t = target(a) orelse return enter(a, .choose);
    a.mind.timer -%= 1;
    if (a.mind.timer == 0) return enter(a, .choose);
    // The point beside the target, on its side.
    const side: i32 = if (t.position.x.lessThan(a.entity.position.x)) 1 else -1;
    a.mind.dest_x = t.position.x.add(Fixed.pixels(n.close_in_beside).times(side));
    a.mind.dest_depth = t.position.depth;
    if (walkTo(a, n.close_in_speed)) {
        return enter(a, .walk_off);
    }
    go(a);
    // Its reach is tested where its walk of this tick takes it.
    if (inReach(a, t)) enter(a, .punch);
}

/// The speed toward its point (`dest`); true when it is there, within 3 pixels both ways (its
/// speed then left as it was).
fn walkTo(a: Actor, speed: Fixed) bool {
    const dx = a.mind.dest_x.whole() - a.entity.position.x.whole();
    const dd = a.mind.dest_depth.whole() - a.entity.position.depth.whole();
    if (@abs(dx) < 4 and @abs(dd) < 4) return true;
    const h = fixed.heading(dx, dd, speed);
    a.entity.velocity.x = h.x;
    a.entity.velocity.depth = h.depth;
    return false;
}

/// Whether its reach (its first jab's box, wherever its frame is) meets the target's body.
fn inReach(a: Actor, t: *const entity.Entity) bool {
    const n = a.numbers();
    const def = a.kind.definition;
    const punch_anim = def.animations[a.kind.animation_of[@backingInt(Animation.punch)]];
    const reach = punch_anim.frames[n.reach_frame].attack orelse return false;
    const body = t.boxes.body orelse return false;
    var me = a.entity.*;
    me.boxes.mirrored = a.entity.facingLeft();
    me.position = me.position.add(me.velocity);
    return systems.meet(&me, &def.boxes[reach], t, &a.tick.kindOf(t).definition.boxes[body]);
}

/// The punch: a string of blows; at the frame before its last, the last punch's box is tested
/// once: when it would not reach, the punch ends; from that last punch on, a blow knocks down.
fn punchSetUp(a: Actor) void {
    if (target(a)) |t| a.faceToward(t);
    a.pause(false);
    a.startMove(.punch);
    a.mind.tested = false;
}

fn punch(a: Actor) void {
    const n = a.numbers();
    const t = target(a) orelse return enter(a, .choose);
    if (a.frame() >= n.last_punch_frame) {
        a.entity.move = a.kind.move_of[@backingInt(Move.punch_last)];
    }
    if (!a.mind.tested and a.frame() == n.last_punch_test) {
        a.mind.tested = true;
        if (!lastPunchReaches(a, t)) return endPunch(a);
    }
    if (a.frame() == n.punch_ends) endPunch(a);
}

fn endPunch(a: Actor) void {
    a.endMove();
    enter(a, .choose);
}

fn lastPunchReaches(a: Actor, t: *const entity.Entity) bool {
    const n = a.numbers();
    const def = a.kind.definition;
    const punch_anim = def.animations[a.kind.animation_of[@backingInt(Animation.punch)]];
    const box = punch_anim.frames[n.last_punch_frame].attack orelse return false;
    const body = t.boxes.body orelse return false;
    var me = a.entity.*;
    me.boxes.mirrored = a.entity.facingLeft();
    return systems.meet(&me, &def.boxes[box], t, &a.tick.kindOf(t).definition.boxes[body]);
}

// Blows -----------------------------------------------------------------------------------------

/// A blow meets its body. Out of hiding and on its feet it reels: the blow's damage is taken at
/// the reel's first tick, as much as the striker's blow does then (a jab that lands on its last
/// frame costs nothing). Reeling, a new blow is taken at once, a touch that goes on is not.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    switch (a.mind.state) {
        .appear, .choose, .knocked_down, .knocked_out, .held => return false,
        .reel => {
            if (!a.mind.reel_taken) return false;
            a.mind.touched = true;
            if (a.mind.touch_taken) return false;
            a.mind.touch_taken = true;
            a.mind.other = blow.attacker;
            if (takeReelBlow(a, blow.damage, blow.reaction == .knock_down, true)) a.mind.settle_wait = true;
            return true;
        },
        else => {},
    }
    a.endMove();
    a.mind.other = blow.attacker;
    a.mind.finishing = blow.reaction == .knock_down;
    a.mind.reel_taken = false;
    a.mind.settling = false;
    a.mind.settle_wait = false;
    enterAtBlow(a, .reel);
    return true;
}

/// A blow taken in a reel: the health it costs; the last health, or a blow that knocks down,
/// knocks it down; a third blow of a combo settles the reel (returns true: at the tick after
/// the next, its pose is set and the reel starts again, without a nudge); else it is nudged
/// back and reels on.
fn takeReelBlow(a: Actor, damage: i16, finishing: bool, at_blow: bool) bool {
    const n = a.numbers();
    a.sound(.hurt);
    a.takeDamage(a.mind.other, damage);
    if (a.entity.health < 0 or finishing) {
        if (at_blow) enterAtBlow(a, .knocked_down) else enter(a, .knocked_down);
        return false;
    }
    // The original reads the striker's state.
    if (a.mind.other) |o| if (a.other(o)) |striker| if (striker.move) |m| {
        if (std.mem.eql(u8, a.tick.kindOf(striker).definition.moves[m].name, "attack3")) {
            a.mind.settling = true;
            return true;
        }
    };
    const back: i32 = if (a.entity.facingLeft()) 1 else -1;
    a.entity.position.x = a.entity.position.x.add(Fixed.pixels(n.reel_nudge).times(back));
    a.mind.timer = n.reel;
    return false;
}

fn reel(a: Actor) void {
    if (!a.mind.reel_taken) {
        a.mind.reel_taken = true;
        a.mind.touch_taken = true;
        if (a.mind.other) |o| if (a.other(o)) |striker| a.faceToward(striker);
        a.animate(.reel);
        a.pause(true);
        const striker = if (a.mind.other) |o| a.other(o) else null;
        const damage = if (striker) |s| a.tick.power(s) else 0;
        if (takeReelBlow(a, damage, a.mind.finishing, false)) return;
        if (a.mind.state != .reel) return;
        a.mind.timer -%= 1;
        return;
    }
    if (a.mind.settle_wait) {
        a.mind.settle_wait = false;
        return;
    }
    if (a.mind.settling) {
        a.mind.settling = false;
        a.setFrame(2);
        a.mind.timer = a.numbers().reel;
        return;
    }
    a.setFrame(a.frame() ^ 1);
    a.mind.timer -%= 1;
    if (a.mind.timer == 0) enter(a, .choose);
}

/// Knocked down: it flies back from the one who struck it (farther with no health left),
/// slowing, bounces twice, lies a while, and gets up; with no health, it is knocked out.
fn knockedDownSetUp(a: Actor) void {
    const n = a.numbers();
    {
        a.mind.down = .flying;
        a.mind.bounces = 0;
        a.mind.slowing = true;
        a.sound(.hurt);
        var x = n.knocked_x;
        if (a.entity.health < 0) {
            x = n.knocked_out_x;
            cry(a);
        }
        // It faces the one who struck it; with none (the special attack's blast), the original
        // reads a striker at the level's left end, and so faces left (a quirk kept).
        const striker = if (a.mind.other) |o| a.other(o) else null;
        if (striker) |s| a.faceToward(s) else a.entity.facing = .left;
        a.animate(.down);
        a.pause(false);
        a.entity.velocity.x = if (a.entity.facingLeft()) x else x.neg();
        a.entity.velocity.height = n.knocked_up;
        a.entity.flags.airborne = true;
    }
}

fn knockedDown(a: Actor) void {
    const n = a.numbers();
    switch (a.mind.down) {
        .flying => {
            if (!a.entity.animation.paused and a.frame() == 1) a.pause(true);
            if (a.mind.slowing and a.mind.bounces == 0) slow(a, n.knocked_slowing);
            gravity(a);
            go(a);
        },
        .sliding => {
            a.mind.timer -%= 1;
            if (a.mind.timer == 0) return slid(a);
            gravity(a);
            go(a);
        },
        .lying => lie(a),
    }
}

/// Lying: a while drawn at its first tick, then it gets up.
fn lie(a: Actor) void {
    const n = a.numbers();
    if (a.entity.animation.paused) {
        a.entity.animation.left = 2 * @as(u8, @intCast(a.pick(.galsia_lying, 4))) + n.lying_least;
        a.pause(false);
    }
    if (a.frame() == n.gets_up_frame) enter(a, .choose);
}

/// A throw's slide ends: it turns, lies on its back, and flies on to its bounces.
fn slid(a: Actor) void {
    if (target(a)) |t| a.faceToward(t);
    a.entity.facing = a.entity.facing.turned();
    a.animate(.down);
    a.setFrame(2);
    a.mind.down = .flying;
    a.mind.slowing = false;
}

/// Its speed across falls toward nothing by `by` a tick.
fn slow(a: Actor, by: Fixed) void {
    const v = a.entity.velocity.x;
    a.entity.velocity.x = if (v.raw < 0) v.add(by) else v.sub(by);
}

/// Its gravity, before it moves, up to its fall's most.
fn gravity(a: Actor) void {
    const n = a.numbers();
    var v = a.entity.velocity.height.add(.of(a.kind.definition.gravity));
    if (!v.lessThan(n.fall_most) and v.raw >= 0) v = n.fall_most;
    a.entity.velocity.height = v;
}

/// In the air after its move: down on the ground or below it, it lands, rising or not, the
/// fraction of its height kept; its gravity is applied before its move (`gravity`).
pub fn fall(a: Actor) void {
    if (a.atGround()) a.land(.fraction_kept);
}

pub fn landed(a: Actor) void {
    const n = a.numbers();
    if (a.mind.state != .knocked_down) return a.stop();
    if (a.mind.down == .sliding) {
        a.sound(.thud);
        slid(a);
        return;
    }
    a.mind.bounces += 1;
    if (a.mind.bounces == 1) {
        if (a.entity.health < 0) cry(a);
        a.pause(true);
        a.setFrame(2);
        var v = a.entity.velocity.height;
        if (v.whole() >= n.bounce_most.whole()) {
            v = .parts(@intCast(n.bounce_most.whole()), v.frac());
            a.sound(.thud);
        }
        return bounce(a, v);
    }
    if (a.mind.bounces == 2) {
        a.sound(.thud);
        return bounce(a, a.entity.velocity.height);
    }
    a.mind.down = .lying;
    a.pace(n.lying, n.lying);
    if (a.entity.health < 0) return enter(a, .knocked_out);
    // It lies from the tick it lands.
    lie(a);
}

/// A bounce: back up, a pixel a tick slower than it came down (its fraction kept, as the
/// original turns the whole pixels alone), and slower across.
fn bounce(a: Actor, down: Fixed) void {
    const n = a.numbers();
    a.entity.velocity.height = .parts(@intCast(1 - down.whole()), down.frac());
    a.entity.flags.airborne = true;
    slow(a, n.bounce_slowing);
}

/// The knockout cry, once: one for an even place across, another for an odd one.
fn cry(a: Actor) void {
    if (a.mind.cried) return;
    a.mind.cried = true;
    if (a.entity.position.x.whole() & 1 != 0) a.sound(.cry_odd) else a.sound(.cry);
}

/// Knocked out: it lies, blinks, and goes.
fn knockedOutSetUp(a: Actor) void {
    const n = a.numbers();
    a.animate(.down);
    a.setFrame(2);
    a.pause(true);
    a.mind.blinks = n.blinks;
    a.mind.timer = n.first_blink;
}

fn knockedOut(a: Actor) void {
    const n = a.numbers();
    a.mind.timer -%= 1;
    if (a.mind.timer != 0) return;
    a.mind.blinks -%= 1;
    if (a.mind.blinks == 0) return a.remove();
    a.entity.flags.hidden = !a.entity.flags.hidden;
    a.mind.timer = n.blink;
}

// Holds -----------------------------------------------------------------------------------------

/// Out of hiding and on its feet, within its height of the one whose reach meets it.
pub fn grabbable(a: Actor, by: Handle) bool {
    switch (a.mind.state) {
        .appear, .choose, .knocked_down, .knocked_out, .held => return false,
        .reel => if (!a.mind.reel_taken) return false,
        else => {},
    }
    const n = a.numbers();
    const holder = a.other(by) orelse return false;
    return @abs(holder.position.height.whole() - a.entity.position.height.whole()) <= n.grab_height;
}

pub fn heldBy(a: Actor, holder: Handle) void {
    a.endMove();
    a.mind.timer = 0;
    a.mind.other = holder;
    a.mind.hold_move = null;
    a.mind.slam = 0;
    enterAtBlow(a, .held);
}

/// Held: its look follows the hold; the holder's blows of the hold (a knee) are taken once each,
/// and it reels while the knee lasts; the last knee's blow knocks it down off the hold.
fn held(a: Actor) void {
    const n = a.numbers();
    if (a.mind.slam != 0) return slamming(a);
    const hh = a.entity.holder orelse return enter(a, .choose);
    const holder = a.other(hh) orelse return enter(a, .choose);
    const hk = a.tick.kindOf(holder);
    const f = a.tick.frameOf(holder);
    const m: *const content_entity.Move = if (holder.move) |i| &hk.definition.moves[i] else {
        // Held in front of the holder (facing it), or from behind.
        a.mind.hold_move = null;
        a.mind.timer = 0;
        return holdLook(a, holder);
    };
    if (m.reaction == .knock_down and f != null and f.?.blow) {
        // Flipped over: knocked down where it is, off the hold.
        a.mind.state = .knocked_down;
        a.mind.fresh = false;
        a.sound(.hurt);
        a.takeDamage(hh, a.tick.power(holder));
        a.tick.letGo(hh);
        a.faceToward(holder);
        a.animate(.down);
        a.pause(true);
        a.setFrame(2);
        a.entity.velocity.x = if (a.entity.facingLeft()) n.flipped_x else n.flipped_x.neg();
        a.entity.velocity.height = n.flipped_up;
        a.entity.flags.airborne = true;
        a.mind.down = .flying;
        a.mind.bounces = 0;
        a.mind.slowing = false;
        return;
    }
    if (m.reaction == .reel and m.damage != 0) {
        if (a.mind.hold_move != holder.move) {
            a.mind.hold_move = holder.move;
            a.sound(.hurt);
            a.takeDamage(hh, a.tick.power(holder));
            if (a.entity.health < 0) {
                enter(a, .knocked_down);
                a.tick.letGo(hh);
                return;
            }
            a.faceToward(holder);
            a.animate(.reel);
            a.pause(true);
            a.setFrame(2);
            a.mind.timer = n.struck_held;
        }
        if (a.mind.timer == 0) return;
        a.setFrame(a.frame() ^ 1);
        a.mind.timer -= 1;
        if (a.mind.timer == 0) {
            a.animate(.thrown);
            a.pause(true);
            a.setFrame(2);
        }
        return;
    }
    if (f) |fr| if (fr.held) |h| if (h.pose) |p| {
        a.animate(if (m.reaction == .slammed) .slammed else .thrown);
        a.pause(true);
        a.setFrame(p);
        return;
    };
    // Vaulted over, it keeps the pose of one held in front.
    if (m.damage == 0) {
        a.animate(.thrown);
        a.pause(true);
        a.setFrame(2);
    }
}

/// The look of one held in front of its holder, or from behind.
fn holdLook(a: Actor, holder: *const entity.Entity) void {
    if (holder.facing == a.entity.facing) {
        a.animate(.down);
        a.pause(true);
        a.setFrame(0);
    } else {
        a.animate(.thrown);
        a.pause(true);
        a.setFrame(2);
    }
}

/// The hold let it go, at the holder's frame then: thrown, it flies off with the throw's damage
/// taken; slammed, it is slammed down there, and knocked down a moment later; else it chooses
/// again.
pub fn letGoBy(a: Actor, holder: Handle) void {
    const n = a.numbers();
    // A hold it left itself (flipped over, knocked out) ends without more.
    if (a.mind.state != .held) return;
    // Let go during its holder's tick, which comes before its own: its next state begins at its
    // next tick.
    a.mind.waits = a.mind.thought != a.tick.world.tick;
    const h = a.other(holder) orelse return enter(a, .choose);
    const hk = a.tick.kindOf(h);
    const move: ?*const content_entity.Move = if (h.move) |m| &hk.definition.moves[m] else null;
    const f = a.tick.frameOf(h);
    const lets_go = f != null and f.?.held != null and f.?.held.?.lets_go;
    if (move == null or !lets_go) {
        if (a.mind.state == .held) enter(a, .choose);
        return;
    }
    const m = move.?;
    switch (m.reaction) {
        .thrown => {
            a.animate(.thrown);
            a.pause(true);
            a.setFrame(1);
            const away: i32 = if (a.entity.position.x.lessThan(h.position.x)) -1 else 1;
            a.entity.velocity.x = n.thrown_x.times(away);
            a.entity.velocity.height = n.thrown_up;
            a.entity.flags.airborne = true;
            a.takeDamage(holder, @intCast(m.damage));
            a.mind.down = .sliding;
            a.mind.timer = n.thrown_slide;
            a.mind.bounces = 0;
            a.mind.slowing = false;
            a.mind.state = .knocked_down;
            a.mind.fresh = false;
        },
        .slammed => {
            a.sound(.thud);
            a.mind.slam = n.slam_ticks;
            a.mind.other = holder;
            a.mind.hold_move = h.move;
            slamming(a);
        },
        else => if (a.mind.state == .held) enter(a, .choose),
    }
}

/// Slammed down: a moment later, knocked down with the slam's damage, flying back.
fn slamming(a: Actor) void {
    const n = a.numbers();
    a.mind.slam -%= 1;
    if (a.mind.slam != 0) return;
    const by = a.mind.other;
    var damage: i16 = 0;
    if (by) |b| if (a.other(b)) |h| if (a.mind.hold_move) |m| {
        damage = @intCast(a.tick.kindOf(h).definition.moves[m].damage);
    };
    a.takeDamage(by, damage);
    a.mind.down = .flying;
    a.mind.bounces = 0;
    a.mind.slowing = false;
    // It flies in the slam's last pose.
    a.pause(true);
    a.entity.velocity.x = if (a.entity.facingLeft()) n.slammed_x else n.slammed_x.neg();
    a.entity.velocity.height = n.slammed_up;
    a.entity.flags.airborne = true;
    a.mind.state = .knocked_down;
    a.mind.fresh = false;
    // It flies from this tick.
    knockedDown(a);
}

// Standing and walking off -------------------------------------------------------------------

/// It stands, facing its target. During the special attack it is held still in a pose by its
/// place across: turning about now and then, lying, or shaking on its feet.
fn standSetUp(a: Actor) void {
    const n = a.numbers();
    if (!a.tick.world.special) {
        a.animate(.stand);
        if (target(a)) |t| a.faceToward(t);
        return;
    }
    switch (a.mind.special_pose) {
        0 => {
            if (target(a)) |t| a.faceToward(t);
            a.animate(.thrown);
            a.pause(true);
            a.setFrame(n.special_spin_frame);
            a.mind.timer = n.special_spin_turn;
        },
        1, 3 => {
            a.entity.facing = .right;
            a.animate(.down);
            a.pause(true);
            a.setFrame(n.special_down_frame);
        },
        2 => {
            if (target(a)) |t| a.faceToward(t);
            a.animate(.walk);
            a.pause(false);
            a.pace(n.special_shake_pace, n.special_shake_pace);
            a.mind.timer = n.special_shake_turn;
        },
    }
}

fn standing(a: Actor) void {
    const n = a.numbers();
    if (!a.tick.world.special or a.mind.special_pose & 1 != 0) return;
    a.mind.timer -%= 1;
    if (a.mind.timer != 0) return;
    a.mind.timer = if (a.mind.special_pose == 0) n.special_spin_turn else n.special_shake_turn;
    a.entity.facing = a.entity.facing.turned();
}

/// The walk off: it walks away from its target in depth (faster when it walks off again soon,
/// and then every other time the other way), to the depths' far bands; then it paces across
/// near its target, a stretch at a time, each of a drawn length and speed, until it is no
/// longer near it, and chooses again.
fn walkOffSetUp(a: Actor) void {
    const n = a.numbers();
    const t = target(a) orelse return;
    a.faceToward(t);
    a.animate(.walk);
    a.pause(false);
    a.pace(n.walk_off_pace, 1);
    a.mind.right_side = !a.entity.position.x.lessThan(t.position.x);
    a.mind.pacing = false;
    a.entity.velocity.x = .zero;
    var v = n.walk_off_depth;
    if (a.mind.retreats >= n.walk_off_faster_after) v = n.walk_off_faster;
    if (a.mind.retreats >= n.walk_off_fastest_after) v = n.walk_off_fastest;
    if (t.position.depth.whole() >= n.walk_off_up_from) v = v.neg();
    a.entity.velocity.depth = v;
    const now = a.tick.world.tick;
    if (now -% a.mind.last_walk_off < n.walk_off_again) {
        if (a.mind.retreats & 1 == 0) a.entity.velocity.depth = a.entity.velocity.depth.neg();
        a.mind.retreats +%= 1;
    } else {
        a.mind.retreats = 0;
    }
    a.mind.last_walk_off = now;
}

fn walkOff(a: Actor) void {
    const n = a.numbers();
    const t = target(a) orelse return enter(a, .choose);
    a.faceToward(t);
    if (!a.mind.pacing) {
        const d = a.entity.position.depth.whole();
        const away = if (a.entity.velocity.depth.raw >= 0) d > n.walk_off_down_to else d < n.walk_off_up_to;
        if (!away) return go(a);
        a.mind.pacing = true;
        a.mind.timer = 0;
    }
    if (a.mind.timer == 0) return pace(a);
    a.mind.timer -= 1;
    const near = if (a.entity.velocity.x.raw >= 0)
        t.position.x.whole() + n.walk_off_near > a.entity.position.x.whole()
    else
        !(t.position.x.whole() - n.walk_off_near > a.entity.position.x.whole());
    if (!near) return enter(a, .choose);
    // Across only.
    const depth_speed = a.entity.velocity.depth;
    a.entity.position.x = a.entity.position.x.add(a.entity.velocity.x);
    a.entity.velocity.depth = depth_speed;
}

/// A new stretch of pacing: its ticks and its speed drawn, away from the target's side.
fn pace(a: Actor) void {
    const n = a.numbers();
    const stretch = a.pick(.galsia_pacing, 4);
    a.mind.timer = switch (stretch) {
        0 => n.pacing_0,
        1 => n.pacing_1,
        2 => n.pacing_2,
        else => n.pacing_3,
    };
    const k = a.pick(.galsia_pacing_speed, 4);
    var v = switch (k) {
        0 => n.pacing_speed_0,
        1 => n.pacing_speed_1,
        2 => n.pacing_speed_2,
        else => n.pacing_speed_3,
    };
    if (a.mind.right_side) v = v.neg();
    a.entity.velocity.x = v;
    a.pace(switch (k) {
        0 => n.pacing_pace_0,
        1 => n.pacing_pace_1,
        2 => n.pacing_pace_2,
        else => n.pacing_pace_3,
    }, 1);
}

/// A player called the special attack while it is on the screen: it stands still, its health
/// gone, until the blast.
pub fn specialCalled(a: Actor) void {
    switch (a.mind.state) {
        .appear, .knocked_out => return,
        else => {},
    }
    if (a.entity.holder) |h| a.tick.letGo(h);
    a.endMove();
    a.mind.other = null;
    a.takeDamage(null, a.entity.health + 1);
    a.mind.special_pose = @intCast(a.entity.position.x.whole() & 3);
    enter(a, .stand);
}

/// The special attack's blast: standing still for it, it is knocked down.
pub fn specialBlast(a: Actor) void {
    if (a.mind.state != .stand or !a.tick.world.special) return;
    enterAtBlow(a, .knocked_down);
}

/// Taken up in its state from a situation another program recorded.
pub fn takeUp(a: Actor) void {
    switch (a.mind.state) {
        .appear => {
            a.entity.flags.hidden = true;
            a.animate(.walk);
        },
        else => a.mind.fresh = true,
    }
}
