//! A player's fighter (Axel, Adam or Blaze): the pad's moves and how it takes the blows of
//! others. Its states are the semantic traces' names; its numbers, animations, moves and sounds
//! are its character's definition's (`entities/axel.json`, `adam.json`, `blaze.json`, from the
//! extractor). Where a character plays a move its own way, its definition says so: a back attack
//! that jumps (`back_attack_up`, Adam's), blows that leap (`last_blow_leap`, `knee_last_leap`,
//! Blaze's), a throw that does not turn (`throw_turns`), and its own frames and ends.
//!
//! As the original's players, it advances its animation itself, one tick at a time, so that the
//! blows of a tick strike with the frame the tick shows (`drives_animation`); and it applies its
//! gravity in its states before it moves.
//!
//! A tick of the player: the combo's window closes; the blow it took at the last tick (hits
//! struck it then) is felt; its blinking runs down; its state acts; its fall is limited; in a
//! hold it goes around the one held, and places it; then its boxes are those of its frame, its
//! body withheld while it blinks.
//!
//! The states, in the game's terms:
//! - `fall`: dropping in at a life's start, or off a ledge; `land`: the crouch of a landing.
//! - `ready`: standing, every move open; `idle`: the idle pose after standing a while; `walk`:
//!   the eight directions, the walk's step kept across a change of direction.
//! - `jump_crouch`, `jump`, `jump_kick`: the jump takes the direction held through its crouch,
//!   steers in the air, and B kicks.
//! - `attack1` to `attack4`: the combo. B starts the first blow; a blow that lands opens a
//!   window in which B continues the chain, and the fourth knocks down. B pressed during the
//!   first blow, before any lands, hurries it and keeps it going: its animation runs on into
//!   another jab. During the first three the pad turns the player.
//! - `back_attack`: B and C together; or, when the character's back attack jumps,
//!   `back_attack_crouch` (the jump's crouch), `back_attack_air` (up, its frames to the last) and
//!   a landing.
//! - `pick_up`: B near an item or a weapon.
//! - armed (a weapon picked up): `armed_stand`, `armed_walk` (a long weapon's own stand and
//!   walk), its jump (`armed_jump_crouch`, `armed_jump`, `armed_land`, `armed_jump_kick`) and back
//!   attack (`armed_back_attack`, or its jump), the weapon unseen then; B swings a pipe
//!   (`armed_swing`), stabs with a knife at a thing ahead within its reach (`armed_stab`, the
//!   traces' `armed_throw`) or else throws it (`armed_attack`, the plain blow). The weapon
//!   strikes, not the player (weapon.zig); a blow taken, a fall or a hold drops it.
//! - `hurt`, `knocked_down` (thrown back, two bounces), `down`, `getting_up`, `recover`: the
//!   player blinks from its getting up, and while it blinks nothing strikes it.
//! - `dying` (thrown back and up, one bounce), `lying_dead`: a blow that takes its last health,
//!   or none left at a tick it is not down nor hurt (the time over's), kills it: a life is lost
//!   (lives.zig); when it has lain dead its time, its next life starts, or it waits to continue.
//! - `grab` (from the front) and `grab_behind`: walking into an enemy grabs it; B knees it (the
//!   third knee is the last, which knocks it down), the pad away and B throws it over the
//!   shoulder (`grab_blow`), C vaults over it to hold it from behind (`throw`), from behind B
//!   slams it down (`vault`, then `vault_land`) and C jumps back over it (`throw_back`); pushing
//!   away lets it go.
//! - `held` and `held_behind`: an enemy holds it from the front (Signal) or from behind (a
//!   stalker), a while, unless it lets go or throws it (`thrown`: over its head, then knocked down
//!   ahead, the throw's damage taken at the first bounce, unless C and up land it on its feet).
//!   Held from behind, C jumps (`escape`) and lands held again, with a moment in which B throws
//!   the holder over (`grab_blow`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const content_entity = @import("../../content/entity.zig");
const Command = @import("../world.zig").Command;
const lives = @import("../lives.zig");

const Fixed = fixed.Fixed;
const Vec3 = fixed.Vec3;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const drives_animation = true;

pub const State = enum {
    fall,
    ready,
    idle,
    walk,
    jump_crouch,
    jump,
    land,
    jump_kick,
    attack1,
    attack2,
    attack3,
    attack4,
    back_attack,
    back_attack_crouch,
    back_attack_air,
    pick_up,
    hurt,
    knocked_down,
    down,
    getting_up,
    recover,
    grab,
    grab_behind,
    knee,
    knee_last,
    grab_blow,
    throw,
    vault,
    vault_land,
    throw_back,
    dying,
    lying_dead,
    held,
    held_behind,
    escape,
    thrown,
    armed_stand,
    armed_walk,
    armed_jump_crouch,
    armed_jump,
    armed_land,
    armed_jump_kick,
    armed_attack,
    armed_stab,
    armed_swing,
    armed_back_attack,
    armed_back_attack_crouch,
    armed_back_attack_air,
};

/// The traces' names of its states that are not theirs.
pub const trace_states = [_]struct { name: []const u8, state: State }{
    // The other program's traces call the knife's stab a throw.
    .{ .name = "armed_throw", .state = .armed_stab },
};

/// A blow taken, felt at the next tick.
pub const Taken = struct {
    by: Handle,
    damage: i16,
    reaction: content_entity.Reaction,
};

/// An enemy's catch, felt at the next tick: who holds it, from behind or the front.
pub const Caught = struct {
    by: Handle,
    behind: bool,
};

pub const Mind = struct {
    state: State = .fall,
    /// An enemy caught it at the last tick, which it feels now; its holder throws it.
    caught_by: ?Caught = null,
    throw_asked: bool = false,
    /// Held from behind, after a jump out: the ticks in which B throws the holder.
    counter_window: u8 = 0,
    /// Thrown by an enemy: the ticks to its next frame; the damage the throw carries to the
    /// landing; whether C and up may still land it on its feet, and whether they did.
    throw_ticks: u8 = 0,
    carried: i16 = 0,
    thrower: ?Handle = null,
    may_recover: bool = false,
    recovers: bool = false,
    /// Whether its life has started (its first tick: it then blinks).
    started: bool = false,
    /// The ticks it still blinks: nothing strikes it.
    blink: u8 = 0,
    /// A blow it took at the last tick, which it feels now.
    taken: ?Taken = null,
    /// Its blow landed at the last tick.
    landed_blow: bool = false,
    /// Its reach caught one at the last tick, which it now holds or lets go.
    caught: bool = false,
    /// The combo: the last blow of the chain, and the ticks of the window in which B continues
    /// it (0: closed).
    chain: State = .attack1,
    window: u8 = 0,
    /// B was pressed during the first blow: it goes on into another.
    queued: bool = false,
    /// A jab went on into another (outside the combo's window): a walk that comes next starts
    /// at `jab_walk_frame` (the original keeps the frame for the jab's start again, which its
    /// unchanged state skips, until a walk takes it up or another state forgets it).
    jab_walk: bool = false,
    /// The knees in this hold, and the pushes away left before it lets go.
    knees: u8 = 0,
    let_go: i8 = 0,
    /// It vaulted over the one it holds (a jump back over it then lands).
    vaulted: bool = false,
    /// A state's timer (hurt, down), and the knock-down's bounces.
    timer: u8 = 0,
    bounces: u8 = 0,
    /// The pause in the air after a jump kick lands: its ticks, and the speed it holds.
    pause: u8 = 0,
    paused_speed: Vec3 = .zero,
    /// The frame of the hold it last went around the one held at.
    placed_frame: ?u8 = null,
    /// The weapon in its hand.
    weapon: ?Handle = null,
};

pub const Animation = enum {
    ready,
    idle,
    walk,
    jump_crouch,
    jump,
    jump_kick,
    attack1,
    attack1_hurried,
    attack3,
    attack4,
    back_attack,
    pick_up,
    hurt,
    knocked_down,
    down,
    getting_up,
    recover,
    grab,
    grab_behind,
    knee,
    knee_last,
    grab_blow,
    throw,
    vault,
    vault_land,
    throw_back,
    lying_dead,
    held,
    held_behind,
    escape,
    counter,
    thrown,
    armed_stand,
    armed_stand_long,
    armed_walk,
    armed_walk_long,
    armed_attack,
    armed_stab,
    armed_swing,
};

pub const Move = enum {
    attack1,
    attack2,
    attack3,
    attack4,
    back_attack,
    jump_kick,
    knee,
    knee_last,
    grab_blow,
    throw,
    vault,
    throw_back,
    counter,
};

pub const Sound = enum { jump, land, hurt, thud, death, armed_blow, throw_weapon, swing_weapon };

pub const Numbers = struct {
    /// The walk across and in depth, straight and diagonal, a logic tick.
    walk_x: Fixed,
    walk_depth: Fixed,
    diagonal_x: Fixed,
    diagonal_depth: Fixed,
    /// The jump's speed up (negative) and across; in the air the pad steers it by `steer` a
    /// tick, up to `steer_most`; a jump kick falls with `kick_falling_gravity`; no fall is faster
    /// than `fall_most`; a fall off a ledge starts at `drop`.
    jump: Fixed,
    jump_x: Fixed,
    steer: Fixed,
    steer_most: Fixed,
    kick_falling_gravity: Fixed,
    fall_most: Fixed,
    drop: Fixed,
    /// Knocked down: its speed back across (negative: away from the one who hit) and up.
    knocked_down_x: Fixed,
    knocked_down_up: Fixed,
    /// Dying: its speed back across and up, and the ticks it lies dead.
    dying_x: Fixed,
    dying_up: Fixed,
    dead: u8,
    /// Ticks: hurt, lying down, blinking, the combo's window, the pause after a jump kick lands.
    hurt: u8,
    down: u8,
    blink: u8,
    combo_window: u8,
    hit_pause: u8,
    /// The pushes away that let go of a hold, less one.
    let_go: u8,
    /// During the special attack, how far ahead of the camera across a player is brought down,
    /// ready.
    special_beyond: i16,
    /// A hurried jab: the ticks of its frame at the press (its blow's frame, or another).
    hurry_first: u8,
    hurry_later: u8,
    /// A jab gone on into another by a queued press: the frame the next walk starts at, and
    /// its ticks.
    jab_walk_frame: u8,
    jab_walk_ticks: u8,
    /// The frames at which states end: the idle pose, the combo's first two blows, its third, its
    /// last.
    idle_ends: u8,
    blow_ends: u8,
    attack3_ends: u8,
    last_blow_ends: u8,
    back_attack_ends: u8,
    getting_up_ends: u8,
    recover_ends: u8,
    vault_ends: u8,
    knee_last_ends: u8,
    grab_blow_ends: u8,
    counter_ends: u8,
    throw_ends: u8,
    /// The throw over the shoulder turns the player first (1) or not (0).
    throw_turns: u8,
    /// Blows that leap: from the combo's last blow's frame `last_blow_leap`, or the last knee's
    /// `knee_last_leap` (none: the blow ends at its frame), the player leaps up (`leap_up`) and
    /// back (`leap_back`), falls as a jump kick does, and lands.
    leap_up: Fixed,
    leap_back: Fixed,
    last_blow_leap: ?u8,
    knee_last_leap: ?u8,
    /// A back attack that jumps: after the jump's crouch, up at this speed in the back attack's
    /// frames, to a landing (none: the back attack is struck standing).
    back_attack_up: ?Fixed,
    /// Where an item is picked up from: its place within these pixels across and in depth, and
    /// up to this height above the feet.
    pick_x: i16,
    pick_depth: i16,
    pick_height: i16,
    /// Held: the jump out's frame at which it is held again with a moment to throw the holder,
    /// and that moment's ticks; thrown: its first frame's ticks, each next one's, the frame it
    /// falls at, how far ahead it falls, its speed up and forward.
    escape_frame: u8,
    escape_window: u8,
    thrown_first: u8,
    thrown_pace: u8,
    thrown_falls: u8,
    thrown_ahead: i16,
    thrown_up: Fixed,
    thrown_x: Fixed,
    /// Held from behind, it is kept this far ahead of its holder.
    held_ahead: i16,
    /// Armed: the frames at which the plain blow and the stab end, and the swing; the plain
    /// blow's frame at which a knife leaves the hand; a knife stabs at a thing ahead within
    /// `stab_reach` across and `stab_level` either way in depth.
    armed_blow_ends: u8,
    armed_swing_ends: u8,
    throw_frame: u8,
    stab_reach: i16,
    stab_level: i16,
};

fn enter(a: Actor, state: State) void {
    a.mind.state = state;
}

/// Changes to `state` with its animation, its move and its speed across (the state's own), as
/// the original's state change does; nothing when it is the state already.
fn change(a: Actor, state: State) void {
    if (a.mind.state == state) return;
    enter(a, state);
    begin(a, state);
}

/// A life starts (the round's start, a new life): the player drops in from where it was put,
/// at its drop's speed.
pub fn startLife(a: Actor) void {
    enter(a, .fall);
    begin(a, .fall);
    a.entity.velocity = .{ .height = a.numbers().drop };
    a.entity.flags.airborne = true;
}

/// Taken up in its state from a situation another program recorded, `elapsed` ticks after it
/// entered it: its state's animation and move, its speed kept, its frames on by the ticks since;
/// but dropping in, its life already started (its blinking over).
pub fn takeUp(a: Actor, elapsed: u32) void {
    if (a.mind.state != .fall) a.mind.started = true;
    const v = a.entity.velocity;
    begin(a, a.mind.state);
    a.entity.velocity = v;
    for (0..@min(elapsed, 255)) |_| _ = a.step();
    const n = a.numbers();
    const gone: u8 = @intCast(@min(elapsed, 255));
    switch (a.mind.state) {
        .attack1, .attack2, .attack3, .attack4 => a.mind.chain = a.mind.state,
        // Its count since it entered the state, as the state's first tick set it.
        .hurt => a.mind.timer = n.hurt -| gone,
        .down => a.mind.timer = n.down -| gone,
        .lying_dead => a.mind.timer = n.dead -| gone,
        else => {},
    }
}

/// Taken up, it got up `ago` ticks before: its blinking, which started then, runs on.
pub fn takeUpBlink(a: Actor, ago: u32) void {
    const n = a.numbers();
    if (ago < n.blink) a.mind.blink = n.blink - @as(u8, @intCast(ago));
}

/// Taken up, it has kneed the one it holds `knees` times in this hold.
pub fn takeUpKnees(a: Actor, knees: u8) void {
    a.mind.knees = knees;
}

/// Taken up, it bounced `times` times in its fall.
pub fn takeUpBounces(a: Actor, times: u8) void {
    a.mind.bounces = times;
}

/// Taken up, its blow in this state landed `ago` ticks before (null: at the situation's tick):
/// the combo's window it opened is open for the rest of its ticks.
pub fn takeUpLanded(a: Actor, ago: ?u32) void {
    const n = a.numbers();
    const t = ago orelse {
        a.mind.landed_blow = true;
        return;
    };
    switch (a.mind.state) {
        .attack1, .attack2, .attack3, .attack4 => {},
        else => return,
    }
    if (t < n.combo_window) a.mind.window = n.combo_window - @as(u8, @intCast(t));
}

/// Taken up, B was pressed in its state of `elapsed` ticks at its ticks `presses` (the trace
/// tells its blow's landing at its tick `landed_at`, if it landed: it knows of it from then): its
/// frames are stepped again as its ticks went. In the first blow a press is queued unless one
/// is, and hurries the blow when it knew of no landing; at the blow's end the queued press is
/// taken up (the first blow again, which goes on as it was).
pub fn takeUpPresses(a: Actor, elapsed: u32, presses: []const u32, landed_at: ?u32) void {
    const n = a.numbers();
    if (a.mind.state != .attack1 or presses.len == 0) return;
    const v = a.entity.velocity;
    begin(a, a.mind.state);
    a.entity.velocity = v;
    var next: usize = 0;
    for (1..@min(elapsed, 255) + 1) |i| {
        _ = a.step();
        while (next < presses.len and presses[next] < i) next += 1;
        if (next < presses.len and presses[next] == i and !a.mind.queued) {
            a.mind.queued = true;
            const open = if (landed_at) |l| l <= i else false;
            if (!open) a.retime(.attack1_hurried, if (a.frame() == 1) n.hurry_first else n.hurry_later);
        }
        if (a.frame() != n.blow_ends or !a.mind.queued) continue;
        a.mind.queued = false;
        a.mind.window = 0;
        a.mind.chain = .attack1;
    }
}

/// The state's animation, move and speed across. A blow queued in the combo's first blows is
/// kept by them alone (the original forgets the moves a new state does not keep).
fn begin(a: Actor, state: State) void {
    const n = a.numbers();
    a.endMove();
    switch (state) {
        .attack1, .attack2, .attack3 => {},
        else => a.mind.queued = false,
    }
    switch (state) {
        .fall, .jump => a.animate(.jump),
        .ready => a.animate(.ready),
        .idle => a.animate(.idle),
        .walk => {
            a.animate(.walk);
            if (a.mind.jab_walk) a.showFrame(n.jab_walk_frame, n.jab_walk_ticks);
        },
        .jump_crouch, .land => a.animate(.jump_crouch),
        .jump_kick => a.startMove(.jump_kick),
        .attack1 => a.startMove(.attack1),
        .attack2 => a.startMove(.attack2),
        .attack3 => a.startMove(.attack3),
        .attack4 => a.startMove(.attack4),
        .back_attack, .back_attack_air => a.startMove(.back_attack),
        .back_attack_crouch, .armed_back_attack_crouch => a.animate(.jump_crouch),
        .pick_up => a.animate(.pick_up),
        .hurt => a.animate(.hurt),
        .knocked_down, .dying => a.animate(.knocked_down),
        .down => a.animate(.down),
        .lying_dead => a.animate(.lying_dead),
        .getting_up => a.animate(.getting_up),
        .recover => a.animate(.recover),
        .grab => a.animate(.grab),
        .grab_behind => a.animate(.grab_behind),
        .knee => a.startMove(.knee),
        .knee_last => a.startMove(.knee_last),
        .grab_blow => a.startMove(.grab_blow),
        .throw => a.startMove(.throw),
        .vault => a.startMove(.vault),
        .vault_land => {
            a.animate(.vault_land);
            a.entity.move = a.kind.move_of[@backingInt(Move.vault)];
        },
        .throw_back => a.startMove(.throw_back),
        .held => a.animate(.held),
        .held_behind => a.animate(.held_behind),
        .escape => a.animate(.escape),
        .thrown => a.animate(.thrown),
        .armed_stand => a.animate(if (weaponLong(a)) .armed_stand_long else .armed_stand),
        .armed_walk => a.animate(if (weaponLong(a)) .armed_walk_long else .armed_walk),
        .armed_jump_crouch, .armed_land => a.animate(.jump_crouch),
        .armed_jump => a.animate(.jump),
        .armed_jump_kick => a.startMove(.jump_kick),
        .armed_attack => a.animate(.armed_attack),
        .armed_stab => a.animate(.armed_stab),
        .armed_swing => a.animate(.armed_swing),
        .armed_back_attack, .armed_back_attack_air => a.startMove(.back_attack),
    }
    // The state's speed: none but a walk's (set each tick by the walk) and a knock-down's,
    // which goes back; a jump kick keeps its speed across.
    const keep_x = state == .jump_kick or state == .armed_jump_kick;
    if (!keep_x) a.entity.velocity.x = switch (state) {
        .knocked_down => n.knocked_down_x.times(a.entity.facing.sign()),
        .dying => n.dying_x.times(a.entity.facing.sign()),
        else => .zero,
    };
    a.entity.velocity.depth = .zero;
    if (state != .knee and state != .grab and state != .knee_last) a.mind.knees = 0;
    a.mind.placed_frame = null;
    a.mind.jab_walk = false;
}

pub fn control(a: Actor, c: Command) void {
    const n = a.numbers();
    if (!a.mind.started) {
        a.mind.started = true;
        a.mind.blink = n.blink;
    }
    // The combo's window closes.
    if (a.mind.window != 0) a.mind.window -= 1;
    // During a special attack it stands still, as it is.
    a.entity.flags.still = a.tick.world.special;
    if (a.tick.world.special) return leftBySpecial(a);
    if (c.pressed.a) callSpecial(a);
    feelBlow(a);
    feelCatch(a);
    if (a.mind.blink != 0) a.mind.blink -= 1;
    act(a, c);
    if (a.entity.velocity.height.order(n.fall_most) == .gt) a.entity.velocity.height = n.fall_most;
    goAround(a);
    placeHeld(a);
    showBoxes(a);
    a.mind.landed_blow = false;
    a.mind.caught = false;
}

/// The boxes of its frame, its body withheld while it blinks; a walk's reach grabs what it meets
/// (the turns answer at this tick, systems.zig).
fn showBoxes(a: Actor) void {
    a.showBoxes();
    if (a.mind.blink != 0) a.entity.boxes.body = null;
    a.entity.flags.wants_grab = a.entity.boxes.attack != null and a.power() == 0;
}

/// The state's tick.
fn act(a: Actor, c: Command) void {
    const n = a.numbers();
    switch (a.mind.state) {
        .fall => gravity(a),
        .ready => {
            a.entity.velocity.height = .zero;
            if (!a.countDown()) return choose(a, c);
            change(a, .idle);
        },
        .idle => {
            a.entity.velocity.height = .zero;
            _ = a.step();
            if (a.frame() != n.idle_ends) return choose(a, c);
            change(a, .ready);
        },
        .walk => {
            a.entity.velocity.height = .zero;
            _ = a.step();
            choose(a, c);
        },
        .jump_crouch, .armed_jump_crouch => {
            if (!a.countDown()) return;
            change(a, if (a.mind.state == .armed_jump_crouch) .armed_jump else .jump);
            a.entity.velocity.height = n.jump;
            a.entity.flags.airborne = true;
            if (c.held.left) {
                a.entity.facing = .left;
                a.entity.velocity.x = n.jump_x.neg();
            } else if (c.held.right) {
                a.entity.facing = .right;
                a.entity.velocity.x = n.jump_x;
            }
        },
        .jump, .armed_jump => {
            gravity(a);
            steer(a, c);
            if (c.pressed.b) change(a, if (a.mind.state == .armed_jump) .armed_jump_kick else .jump_kick);
        },
        .jump_kick, .armed_jump_kick => {
            if (hitPause(a)) return;
            kickGravity(a);
            toLastFrame(a);
        },
        .back_attack_crouch, .armed_back_attack_crouch => {
            if (!a.countDown()) return;
            change(a, if (a.mind.state == .armed_back_attack_crouch) .armed_back_attack_air else .back_attack_air);
            a.entity.velocity.height = n.back_attack_up orelse .zero;
            a.entity.flags.airborne = true;
        },
        .back_attack_air, .armed_back_attack_air => {
            toLastFrame(a);
            gravity(a);
        },
        .land => {
            if (!a.countDown()) return;
            change(a, .ready);
        },
        .armed_land => {
            if (!a.countDown()) return;
            change(a, .armed_stand);
        },
        .armed_stand => {
            a.entity.velocity.height = .zero;
            choose(a, c);
        },
        .armed_walk => {
            a.entity.velocity.height = .zero;
            _ = a.step();
            choose(a, c);
        },
        .armed_attack, .armed_stab => weaponBlow(a, c, n.armed_blow_ends),
        .armed_swing, .armed_back_attack => weaponBlow(a, c, n.armed_swing_ends),
        .attack1, .attack2, .attack3 => {
            _ = a.step();
            if (a.mind.landed_blow) a.mind.window = n.combo_window;
            if (a.mind.state == .attack1 and c.pressed.b and !a.mind.queued) {
                a.mind.queued = true;
                if (a.mind.window == 0) a.retime(.attack1_hurried, if (a.frame() == 1) n.hurry_first else n.hurry_later);
            }
            turn(a, c);
            if (a.frame() == if (a.mind.state == .attack3) n.attack3_ends else n.blow_ends) choose(a, c);
        },
        .attack4 => {
            _ = a.step();
            if (n.last_blow_leap) |from| if (a.frame() >= from) return leap(a);
            if (a.frame() == n.last_blow_ends) choose(a, c);
        },
        .back_attack => {
            _ = a.step();
            if (a.frame() == n.back_attack_ends) choose(a, c);
        },
        .pick_up => if (a.countDown()) choose(a, c),
        .hurt => {
            _ = a.step();
            a.mind.timer -%= 1;
            if (a.mind.timer == 0) change(a, .ready);
        },
        .knocked_down, .dying => gravity(a),
        .lying_dead => {
            _ = a.step();
            a.mind.timer -%= 1;
            if (a.mind.timer == 0) return lives.lifeOver(a.tick, a.handle);
        },
        .down => {
            a.mind.timer -%= 1;
            if (a.mind.timer == 0) change(a, .getting_up);
        },
        .getting_up => {
            _ = a.step();
            if (a.frame() != n.getting_up_ends) return;
            if (a.mind.blink == 0) a.mind.blink = n.blink;
            change(a, .recover);
        },
        .recover => {
            _ = a.step();
            if (a.frame() == n.recover_ends) choose(a, c);
        },
        .grab, .grab_behind => hold(a, c),
        .knee => if (a.countDown()) change(a, .grab),
        .knee_last => {
            _ = a.step();
            if (n.knee_last_leap) |from| {
                if (a.frame() < from) return;
                if (a.entity.holding != null) a.letGo();
                return leap(a);
            }
            if (a.frame() != n.knee_last_ends) return;
            a.letGo();
            choose(a, c);
        },
        .grab_blow => {
            _ = a.step();
            const countering = a.entity.move == a.kind.move_of[@backingInt(Move.counter)];
            if (a.frame() == if (countering) n.counter_ends else n.grab_blow_ends) choose(a, c);
        },
        .vault => {
            _ = a.step();
            if (a.frame() != n.vault_ends) return;
            change(a, .vault_land);
        },
        .vault_land => if (a.step()) {
            if (a.frame() == 0) choose(a, c);
        },
        .throw, .throw_back => {
            _ = a.step();
            if (a.frame() != n.throw_ends) return;
            vaultEnds(a);
        },
        .held => heldFront(a),
        .held_behind => heldBehind(a, c),
        .escape => escape(a),
        .thrown => thrown(a),
    }
    if (a.mind.state == .knocked_down and a.mind.may_recover and c.pressed.c and c.held.up) {
        a.mind.may_recover = false;
        a.mind.recovers = true;
    }
}

/// The actions open in ready, idle and walk, and at the end of a blow: a grab its reach caught,
/// the back attack, a jump, a blow (or a pick-up), else the walk by the pad.
fn choose(a: Actor, c: Command) void {
    if (a.mind.weapon != null) return armedChoose(a, c);
    if (caught(a)) return;
    if ((c.held.b and c.pressed.c) or (c.held.c and c.pressed.b)) return change(a, if (a.numbers().back_attack_up != null) .back_attack_crouch else .back_attack);
    if (c.pressed.c) {
        a.sound(.jump);
        return change(a, .jump_crouch);
    }
    if (attack(a, c)) return;
    walk(a, c);
}

/// B, or a press queued in the first blow: a pick-up when an item is near; else, while a blow's
/// window is open, the chain's next blow (after the fourth, the first again); else the first.
fn attack(a: Actor, c: Command) bool {
    const queued = a.mind.queued;
    a.mind.queued = false;
    if (!queued and !c.pressed.b) return false;
    if (queued) a.mind.jab_walk = true;
    if (pickUp(a)) return true;
    var next: State = .attack1;
    if (a.mind.window != 0) {
        a.mind.jab_walk = false;
        next = switch (a.mind.chain) {
            .attack1 => .attack2,
            .attack2 => .attack3,
            .attack3 => .attack4,
            else => .attack1,
        };
    }
    a.mind.window = 0;
    a.mind.chain = next;
    change(a, next);
    return true;
}

/// The walk by the pad's directions (right before left, up before down); none stops it.
fn walk(a: Actor, c: Command) void {
    const n = a.numbers();
    const across: i32 = if (c.held.right) 1 else if (c.held.left) -1 else 0;
    const depth: i32 = if (c.held.up) -1 else if (c.held.down) 1 else 0;
    if (across == 0 and depth == 0) {
        if (a.mind.state != .ready and a.mind.state != .idle) change(a, .ready);
        return;
    }
    if (across != 0) a.entity.facing = if (across < 0) .left else .right;
    if (a.mind.state != .walk) change(a, .walk);
    const diagonal = across != 0 and depth != 0;
    a.entity.velocity.x = (if (diagonal) n.diagonal_x else n.walk_x).times(across);
    a.entity.velocity.depth = (if (diagonal) n.diagonal_depth else n.walk_depth).times(depth);
}

/// The pad's left or right turns the player (in the first blows).
fn turn(a: Actor, c: Command) void {
    if (c.held.left) a.entity.facing = .left else if (c.held.right) a.entity.facing = .right;
}

fn gravity(a: Actor) void {
    a.entity.velocity.height = a.entity.velocity.height.add(.of(a.kind.definition.gravity));
}

/// A jump kick's gravity, and a leap's: its own going up, a lighter one coming down.
fn kickGravity(a: Actor) void {
    if (a.entity.velocity.height.raw < 0) return gravity(a);
    a.entity.velocity.height = a.entity.velocity.height.add(a.numbers().kick_falling_gravity);
}

/// Its animation runs on to its last frame, which then stays (a jump kick's, a jumping back
/// attack's).
fn toLastFrame(a: Actor) void {
    if (!a.atLastFrame()) _ = a.step();
}

/// A blow that leaps: once, up and back from the side it faces; then it falls as a jump kick
/// does, to a landing.
fn leap(a: Actor) void {
    const n = a.numbers();
    if (a.entity.velocity.height.raw == 0) {
        a.entity.velocity.height = n.leap_up;
        a.entity.velocity.x = n.leap_back.times(-a.entity.facing.sign());
        a.entity.flags.airborne = true;
    }
    kickGravity(a);
}

/// In the air, the pad steers the jump toward its side, up to the most.
fn steer(a: Actor, c: Command) void {
    const n = a.numbers();
    var v = a.entity.velocity.x;
    if (c.held.right) {
        a.entity.facing = .right;
        v = v.add(n.steer);
    } else if (c.held.left) {
        a.entity.facing = .left;
        v = v.sub(n.steer);
    } else return;
    a.entity.velocity.x = v.clamp(n.steer_most.neg(), n.steer_most);
}

/// After a jump kick lands, the kick holds still in the air a moment: no move, no gravity.
fn hitPause(a: Actor) bool {
    const n = a.numbers();
    if (a.mind.pause != 0) {
        a.mind.pause -= 1;
        if (a.mind.pause == 0) {
            a.entity.velocity = a.mind.paused_speed;
            return true;
        }
        a.entity.velocity = .zero;
        return true;
    }
    if (!a.mind.landed_blow) return false;
    a.mind.pause = n.hit_pause;
    a.mind.paused_speed = a.entity.velocity;
    a.entity.velocity = .zero;
    return true;
}

// Taking blows ---------------------------------------------------------------------------------

/// Struck and not yet back on its feet (hurt to its recovery, thrown, dying): the special attack
/// leaves it as it is (the original's players keep a mark of it through these states).
fn struckDown(state: State) bool {
    return switch (state) {
        .hurt, .knocked_down, .down, .getting_up, .recover, .dying, .lying_dead, .thrown => true,
        else => false,
    };
}

/// Down or hurt: no blow is felt, and no health left does not kill it yet.
fn downOrHurt(state: State) bool {
    return switch (state) {
        .hurt, .knocked_down, .down, .getting_up, .dying, .lying_dead => true,
        else => false,
    };
}

/// The blow taken at the last tick: in the air, or a blow that knocks down, it is knocked down
/// facing the one who hit (with the hurt's sound); else it is hurt, facing it. A blow that
/// takes its last health kills it; with no health left (the time over took it), it dies at a
/// tick it is not down nor hurt.
fn feelBlow(a: Actor) void {
    if (a.entity.health <= 0 and !downOrHurt(a.mind.state)) {
        a.mind.taken = null;
        return die(a, null);
    }
    const t = a.mind.taken orelse return;
    a.mind.taken = null;
    const n = a.numbers();
    if (a.other(t.by)) |by| faceStriker(a, by);
    const knocked = t.reaction == .knock_down or a.entity.flags.airborne;
    if (knocked) a.tick.sound(fallSound(a, t.by), a.handle);
    dropWeapon(a);
    loses(a, t.by, t.damage);
    if (a.entity.health <= 0) return die(a, t.by);
    if (!knocked) a.sound(.hurt);
    if (a.entity.holding != null or a.entity.holder != null) a.letGo();
    if (knocked) {
        change(a, .knocked_down);
        a.mind.bounces = 0;
        a.entity.velocity.height = n.knocked_down_up;
        a.entity.flags.airborne = true;
        return;
    }
    change(a, .hurt);
    a.mind.timer = n.hurt;
}

/// Struck by `by`, it faces it: left unless it is left of it (whole pixels), as the original's
/// struck player turns.
fn faceStriker(a: Actor, by: *const entity.Entity) void {
    a.entity.facing = if (a.entity.position.x.whole() >= by.position.x.whole()) .left else .right;
}

/// The sound of its knock-down by `by`: the hurt's, or the one its striker's kind gives those
/// it fells (`fells`: the brawler's).
fn fallSound(a: Actor, by: Handle) []const u8 {
    if (a.other(by)) |s| if (a.tick.kindOf(s).definition.sound("fells")) |own| return own;
    return a.kind.sound_of[@backingInt(Sound.hurt)];
}

/// It loses `damage` health, down to none (the original's player keeps no less): what it lost is
/// told.
fn loses(a: Actor, by: ?Handle, damage: i16) void {
    a.takeDamage(by, @min(damage, @max(a.entity.health, 0)));
}

/// It dies: its cry, a hold let go, thrown back from the one who struck (facing it) and up, a
/// life less.
fn die(a: Actor, by: ?Handle) void {
    dropWeapon(a);
    const n = a.numbers();
    a.sound(.death);
    if (a.entity.holding != null or a.entity.holder != null) a.letGo();
    // Facing the one who struck: left when it is left of it (whole pixels).
    if (by) |h| if (a.other(h)) |o| {
        a.entity.facing = if (o.position.x.whole() < a.entity.position.x.whole()) .left else .right;
    };
    change(a, .dying);
    a.mind.bounces = 0;
    a.entity.velocity.height = n.dying_up;
    a.entity.flags.airborne = true;
    lives.lose(a.tick, a.handle);
}

/// A blow meets its body: it feels it at the next tick.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (!catchable(a)) return false;
    a.mind.taken = .{ .by = blow.attacker, .damage = blow.damage, .reaction = blow.reaction };
    return true;
}

pub fn blowLanded(a: Actor, target: Handle) void {
    _ = target;
    a.mind.landed_blow = true;
}

/// In the air after its move: it lands once it comes down to the ground, on its whole pixels;
/// its gravity is its state's, applied before its move (`act`).
pub fn fall(a: Actor) void {
    if (a.entity.velocity.height.raw >= 0 and a.atGround()) a.land(.whole);
}

pub fn landed(a: Actor) void {
    const n = a.numbers();
    switch (a.mind.state) {
        .knocked_down => {
            if (a.mind.recovers) {
                // Landed on its feet: the throw's damage spared.
                a.mind.recovers = false;
                a.mind.may_recover = false;
                a.mind.carried = 0;
                a.sound(.land);
                change(a, .land);
                a.entity.velocity.height = .zero;
                showBoxes(a);
                return;
            }
            a.mind.bounces += 1;
            if (a.mind.bounces == 1 and a.mind.carried != 0) {
                loses(a, a.mind.thrower, a.mind.carried);
                a.mind.carried = 0;
            }
            a.sound(.thud);
            if (a.mind.bounces < 2) {
                // A bounce: half the speed of the fall, back up, lying.
                a.animate(.down);
                a.entity.velocity.height = a.entity.velocity.height.neg().shr(1);
                a.entity.flags.airborne = true;
                return;
            }
            change(a, .down);
            a.mind.timer = n.down;
        },
        .dying => {
            a.mind.bounces += 1;
            a.sound(.thud);
            if (a.mind.bounces < 2) {
                a.animate(.down);
                a.entity.velocity.height = a.entity.velocity.height.neg().shr(1);
                a.entity.flags.airborne = true;
                return;
            }
            change(a, .lying_dead);
            a.mind.timer = n.dead;
        },
        .fall, .jump, .jump_kick, .back_attack_air, .attack4, .knee_last => {
            a.sound(.land);
            change(a, .land);
        },
        .armed_jump, .armed_jump_kick, .armed_back_attack_air => {
            a.sound(.land);
            change(a, if (a.mind.weapon != null) .armed_land else .land);
        },
        else => {},
    }
    a.entity.velocity.height = .zero;
    showBoxes(a);
}

// Holds ----------------------------------------------------------------------------------------

/// Its reach caught one at the last tick: it holds it from the front when they face each other,
/// from behind when it faces the other's back; else it lets go.
fn caught(a: Actor) bool {
    if (!a.mind.caught) return false;
    const h = a.entity.holding orelse return false;
    const held = a.other(h) orelse return false;
    const n = a.numbers();
    const behind = held.facing == a.entity.facing and switch (a.entity.facing) {
        .right => held.position.x.order(a.entity.position.x) != .lt,
        .left => held.position.x.order(a.entity.position.x) == .lt,
    };
    if (held.facing == a.entity.facing and !behind) {
        a.letGo();
        return false;
    }
    a.mind.let_go = @intCast(n.let_go);
    a.mind.vaulted = false;
    change(a, if (behind) .grab_behind else .grab);
    return true;
}

pub fn holds(a: Actor, held: Handle) void {
    _ = held;
    a.mind.caught = true;
}

/// Holding: C vaults over the one held (from behind, jumps back over it); B knees it, or with
/// the pad away throws it over the shoulder (from behind, slams it down); pushing away lets it
/// go.
fn hold(a: Actor, c: Command) void {
    if (a.entity.holding == null or a.other(a.entity.holding.?) == null) {
        a.entity.holding = null;
        return change(a, .ready);
    }
    a.entity.velocity.height = .zero;
    if (c.pressed.c) {
        a.sound(.jump);
        return change(a, if (a.mind.state == .grab_behind) .throw_back else .throw);
    }
    if (a.mind.state == .grab_behind) {
        if (c.pressed.b) return change(a, .vault);
    } else if (c.pressed.b) {
        const away = (c.held.left and a.entity.facing == .right) or (c.held.right and a.entity.facing == .left);
        if (away) {
            if (a.numbers().throw_turns != 0) a.entity.facing = a.entity.facing.turned();
            return change(a, .grab_blow);
        }
        a.mind.knees += 1;
        const knees = a.mind.knees;
        change(a, if (knees >= 3) .knee_last else .knee);
        a.mind.knees = knees;
        return;
    }
    // Pushing away lets go, turned away from it.
    const away = (c.held.left and a.entity.facing == .right) or (c.held.right and a.entity.facing == .left);
    if (!away) return;
    a.mind.let_go -= 1;
    if (a.mind.let_go >= 0) return;
    a.letGo();
    a.entity.facing = a.entity.facing.turned();
    change(a, if (a.mind.weapon != null) .armed_stand else .ready);
}

/// The vault over the one held ends behind it: the player turns and holds it from behind. A
/// jump back over it ends in a landing once it has vaulted (the hold lets go), else holding it
/// from the front: a quirk of the original, which remembers a vault until the next grab.
fn vaultEnds(a: Actor) void {
    a.entity.facing = a.entity.facing.turned();
    a.sound(.land);
    if (a.mind.state == .throw) {
        a.mind.vaulted = true;
        return change(a, .grab_behind);
    }
    if (!a.mind.vaulted) {
        a.mind.vaulted = true;
        return change(a, .grab);
    }
    a.letGo();
    change(a, if (a.mind.weapon != null) .armed_land else .land);
}

/// In a vault or a throw, the player goes around the one held, at each new frame of its hold
/// (`place`): the held one's whole pixels and the place's, its own fractions kept.
fn goAround(a: Actor) void {
    const h = a.entity.holding orelse return;
    const f = a.currentFrame() orelse return;
    const p = f.place orelse return;
    if (a.mind.placed_frame == a.frame()) return;
    a.mind.placed_frame = a.frame();
    const held = a.other(h) orelse return;
    const at = held.position;
    const e = a.entity;
    e.position.x = .parts(@intCast(at.x.whole() + @as(i32, p.x) * e.facing.sign()), e.position.x.frac());
    e.position.height = .parts(@intCast(at.height.whole() + p.height), e.position.height.frac());
}

/// The one held, where the frame of the hold puts it (`held`): its whole pixels the holder's and
/// the frame's, its own fractions kept (as the original's held enemies place themselves); at a
/// frame that lets it go, the hold ends there.
fn placeHeld(a: Actor) void {
    const h = a.entity.holding orelse return;
    const f = a.currentFrame() orelse return;
    const where = f.held orelse return;
    const held = a.other(h) orelse return;
    const at = a.entity.position;
    const was = held.position;
    // A boss takes its places in a hold itself.
    if (a.tick.kindOf(held).family() != .boss) held.position = .{
        .x = .parts(@intCast(at.x.whole() + @as(i32, where.x) * a.entity.facing.sign()), was.x.frac()),
        .depth = .parts(@intCast(at.depth.whole()), was.depth.frac()),
        .height = .parts(@intCast(at.height.whole() + where.height), was.height.frac()),
    };
    if (where.lets_go) a.letGo();
}

// Held by an enemy --------------------------------------------------------------------------

/// An enemy caught it at the last tick: it is held from the front or from behind, its own hold
/// ended.
fn feelCatch(a: Actor) void {
    const got = a.mind.caught_by orelse return;
    a.mind.caught_by = null;
    if (a.entity.holder == null) return;
    if (a.entity.holding != null) a.letGo();
    dropWeapon(a);
    a.mind.thrower = got.by;
    a.mind.counter_window = 0;
    change(a, if (got.behind) .held_behind else .held);
    a.entity.velocity = .zero;
}

/// It takes one blow or catch a tick, the first (the original's players take one hit a tick).
pub fn catchable(a: Actor) bool {
    return a.mind.taken == null and a.mind.caught_by == null;
}

/// Whether an enemy may set on it now: not while it blinks, nor from a blow or a fall until it
/// stands again (hurt, knocked down, down but at the tick it lay down, getting up or
/// recovering; dying or dead).
pub fn attackable(a: Actor) bool {
    if (a.mind.blink != 0) return false;
    return switch (a.mind.state) {
        .down => a.mind.timer == a.numbers().down,
        .hurt, .knocked_down, .getting_up, .recover, .dying, .lying_dead => false,
        else => true,
    };
}

/// `holder` holds it from now (its own catch, or a hold turned).
pub fn caughtBy(a: Actor, holder: Handle, behind: bool) void {
    a.mind.caught_by = .{ .by = holder, .behind = behind };
}

/// Its holder throws it, a throw of `damage` taken at the landing: it feels it at its next tick.
pub fn thrownBy(a: Actor, holder: Handle, damage: i16) void {
    _ = holder;
    a.mind.throw_asked = true;
    a.mind.carried = damage;
}

/// Held from the front: a while, unless its holder lets go or throws it.
fn heldFront(a: Actor) void {
    const n = a.numbers();
    a.entity.velocity.height = .zero;
    if (a.entity.holder == null) return change(a, .ready);
    if (a.mind.throw_asked) {
        a.mind.throw_asked = false;
        const carried = a.mind.carried;
        change(a, .thrown);
        a.mind.carried = carried;
        a.mind.throw_ticks = n.thrown_first;
        placeFromHolder(a);
        return;
    }
    if (!a.countDown()) return;
    a.letGo();
    change(a, .ready);
}

/// Held from behind: in the moment after a jump out, B throws the holder over (the hold
/// turned); C jumps out; after a while it is free.
fn heldBehind(a: Actor, c: Command) void {
    a.entity.velocity.height = .zero;
    if (a.entity.holder == null) return change(a, .ready);
    if (a.mind.counter_window != 0) {
        a.mind.counter_window -= 1;
        if (a.mind.counter_window != 0 and c.pressed.b) {
            a.mind.counter_window = 0;
            if (a.tick.turnHold(a.handle)) {
                change(a, .grab_blow);
                a.startMove(.counter);
                return;
            }
        }
    }
    if (c.pressed.c) {
        a.sound(.jump);
        return change(a, .escape);
    }
    if (!a.countDown()) return;
    a.letGo();
    change(a, .ready);
}

/// The jump out of a hold from behind: at its frame, held again, with the moment to throw the
/// holder.
fn escape(a: Actor) void {
    const n = a.numbers();
    if (a.entity.holder == null) return change(a, .ready);
    _ = a.step();
    if (a.frame() != n.escape_frame) return;
    a.mind.counter_window = n.escape_window;
    enter(a, .held_behind);
    begin(a, .held_behind);
}

/// Thrown over its holder's head: a frame at a time, each placed from the holder; at its last,
/// it falls ahead, knocked down, the holder's blow carried to the landing.
fn thrown(a: Actor) void {
    const n = a.numbers();
    a.mind.throw_ticks -%= 1;
    if (a.mind.throw_ticks != 0) return placeFromHolder(a);
    if (a.frame() == n.thrown_falls) return throwFall(a);
    a.mind.throw_ticks = n.thrown_pace;
    a.showFrame(a.frame() + 1, null);
    placeFromHolder(a);
}

/// At a new frame of a throw, it is placed from its holder by the frame's place: its whole
/// pixels the holder's and the place's, its own fractions kept.
fn placeFromHolder(a: Actor) void {
    const h = a.entity.holder orelse return;
    const f = a.currentFrame() orelse return;
    const p = f.place orelse return;
    if (a.mind.placed_frame == a.frame()) return;
    a.mind.placed_frame = a.frame();
    const holder = a.other(h) orelse return;
    const at = holder.position;
    const e = a.entity;
    e.position.x = .parts(@intCast(at.x.whole() + @as(i32, p.x) * e.facing.sign()), e.position.x.frac());
    e.position.height = .parts(@intCast(at.height.whole() + p.height), e.position.height.frac());
    e.position.depth = .parts(@intCast(at.depth.whole()), e.position.depth.frac());
}

fn throwFall(a: Actor) void {
    const n = a.numbers();
    a.entity.position.x = a.entity.position.x.add(Fixed.pixels(n.thrown_ahead).times(a.entity.facing.sign()));
    a.letGo();
    change(a, .knocked_down);
    a.mind.bounces = 0;
    a.entity.flags.airborne = true;
    a.entity.velocity.height = n.thrown_up;
    a.entity.velocity.x = if (a.entity.velocity.x.raw < 0) n.thrown_x else n.thrown_x.neg();
    a.mind.may_recover = true;
}

// The special attack -------------------------------------------------------------------------

/// During the special attack, a player on the ground whom the camera's run back has left beyond
/// its view's right side is put down there, still, and stands ready: a hold it was in ends (the
/// special attack itself ends none).
fn leftBySpecial(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    if (e.velocity.height.raw != 0 or struckDown(a.mind.state)) return;
    if (e.position.x.whole() < a.tick.world.camera.x.whole() + n.special_beyond) return;
    e.position.height = .parts(@intCast(a.tick.world.ground.whole()), e.position.height.frac());
    e.velocity = .zero;
    e.flags.airborne = false;
    switch (a.mind.state) {
        .ready, .idle => return,
        else => {},
    }
    if (e.holding != null or e.holder != null) a.letGo();
    change(a, .ready);
    // Its boxes are none until its tick shows them again, at the special attack's end (the
    // original's frame is not yet read as it stands it up).
    e.boxes.body = null;
    e.boxes.attack = null;
}

/// A (the special attack): standing in play (not dropping in), with health and a special left,
/// it calls the police car.
fn callSpecial(a: Actor) void {
    if (a.entity.health <= 0 or a.mind.state == .fall) return;
    const k = a.tick.world.playerOf(a.handle) orelse return;
    const p = &a.tick.world.players[k];
    if (p.specials == 0) return;
    if (!a.tick.callSpecial(a.handle)) return;
    p.specials -= 1;
}

// Items ----------------------------------------------------------------------------------------

/// An item or a weapon near its feet is picked up.
fn pickUp(a: Actor) bool {
    const n = a.numbers();
    const item = a.itemNear(n.pick_x, n.pick_depth, n.pick_height) orelse return false;
    change(a, .pick_up);
    a.pickUp(item);
    return true;
}

/// It picks up `item`: a weapon is in its hand from now (one it held already lies where it was).
pub fn picks(a: Actor, item: Handle) void {
    const o = a.other(item) orelse return;
    if (a.tick.kindOf(o).family() != .weapon) return;
    if (a.mind.weapon) |old| a.tick.putDownWeapon(old);
    a.mind.weapon = item;
}

/// Taken up holding the weapon `w`.
pub fn takeUpWeapon(a: Actor, w: Handle) void {
    a.mind.weapon = w;
}

// Armed ------------------------------------------------------------------------------------------

/// The weapon in its hand, while it holds it still.
fn weaponHeld(a: Actor) ?*entity.Entity {
    const w = a.mind.weapon orelse return null;
    const o = a.other(w) orelse return null;
    if (o.holder == null or !o.holder.?.eql(a.handle)) return null;
    return o;
}

/// Whether its weapon is a long one (its stand and walk are its own).
fn weaponLong(a: Actor) bool {
    const w = weaponHeld(a) orelse return false;
    return (a.tick.kindOf(w).definition.number("long") orelse 0) != 0;
}

/// Its weapon drops from its hand.
fn dropWeapon(a: Actor) void {
    const w = a.mind.weapon orelse return;
    a.mind.weapon = null;
    a.tick.dropWeapon(w);
}

/// The actions open armed (standing, walking, at a blow's end): a grab its reach caught, the back
/// attack, a jump, B (a pick-up first; a swing with a weapon swung, a stab at a thing ahead with
/// one thrown, else the plain blow, which throws one thrown), else the walk by the pad; its weapon
/// no longer in its hand, it is unarmed.
fn armedChoose(a: Actor, c: Command) void {
    if (caught(a)) return;
    if ((c.held.b and c.pressed.c) or (c.held.c and c.pressed.b)) return change(a, if (a.numbers().back_attack_up != null) .armed_back_attack_crouch else .armed_back_attack);
    if (c.pressed.c) {
        a.sound(.jump);
        return change(a, .armed_jump_crouch);
    }
    if (c.pressed.b) {
        if (pickUp(a)) return;
        const w = weaponHeld(a) orelse return change(a, .armed_attack);
        const def = a.tick.kindOf(w).definition;
        if ((def.number("swung") orelse 0) != 0) {
            a.sound(.swing_weapon);
            return change(a, .armed_swing);
        }
        if ((def.number("thrown") orelse 0) != 0 and thingAhead(a)) return change(a, .armed_stab);
        return change(a, .armed_attack);
    }
    if (weaponHeld(a) == null) {
        a.mind.weapon = null;
        return walk(a, c);
    }
    armedWalk(a, c);
}

/// The walk by the pad, armed; none: it stands armed.
fn armedWalk(a: Actor, c: Command) void {
    const n = a.numbers();
    const across: i32 = if (c.held.right) 1 else if (c.held.left) -1 else 0;
    const depth: i32 = if (c.held.up) -1 else if (c.held.down) 1 else 0;
    if (across == 0 and depth == 0) {
        if (a.mind.state != .armed_stand) change(a, .armed_stand);
        return;
    }
    if (across != 0) a.entity.facing = if (across < 0) .left else .right;
    if (a.mind.state != .armed_walk) change(a, .armed_walk);
    const diagonal = across != 0 and depth != 0;
    a.entity.velocity.x = (if (diagonal) n.diagonal_x else n.walk_x).times(across);
    a.entity.velocity.depth = (if (diagonal) n.diagonal_depth else n.walk_depth).times(depth);
}

/// Whether a thing is ahead within a stab's reach: in the enemies' places, on the side it faces
/// (dead level across counts facing right), within the reach across and the level in depth.
fn thingAhead(a: Actor) bool {
    const n = a.numbers();
    const e = a.entity;
    const places = @import("../world.zig").World.enemy_places;
    for (places.from..places.to) |i| {
        const o = &a.tick.world.entities[i];
        if (!o.alive()) continue;
        const dx = o.position.x.whole() - e.position.x.whole();
        const ahead = if (e.facing == .right) dx >= 0 else dx < 0;
        if (!ahead or @abs(dx) >= n.stab_reach) continue;
        const dd = o.position.depth.whole() - e.position.depth.whole();
        if (dd < -n.stab_level or dd >= n.stab_level) continue;
        return true;
    }
    return false;
}

/// A blow with the weapon: its frames run; the plain blow's frame that holds a knife out throws
/// it (else it sounds the blow); at the blow's last frame (`ends`) the actions are open again.
fn weaponBlow(a: Actor, c: Command, ends: u8) void {
    const n = a.numbers();
    const was = a.frame();
    _ = a.step();
    if (a.mind.state == .armed_attack and a.frame() == n.throw_frame and a.frame() != was) {
        const w = weaponHeld(a);
        const throws = if (w) |x| (a.tick.kindOf(x).definition.number("thrown") orelse 0) != 0 else false;
        if (throws) {
            a.tick.throwWeapon(a.mind.weapon.?);
            a.mind.weapon = null;
            a.sound(.throw_weapon);
        } else a.sound(.armed_blow);
    }
    if (a.frame() == ends) choose(a, c);
}
