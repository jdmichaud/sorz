//! A player's fighter (Axel, Adam or Blaze): the pad's moves and how it takes the blows of
//! others. Its states are the semantic traces' names; its numbers, animations, moves and sounds
//! are its character's definition's (`entities/axel.json`, `adam.json`, `blaze.json`, from the
//! extractor). Where a character plays a move its own way, its definition says so: a back attack
//! that jumps (`back_attack_up`, Adam's), blows that leap (`last_blow_leap`, `knee_last_leap`,
//! Blaze's), a throw that does not turn (`throw_turns`), and its own frames and ends.
//!
//! It acts on its command's actions (`Command`: the special attack, the attack, the jump), which
//! the options' CONTROL gives buttons; below, A, B and C name them by the cartridge's first
//! layout: A the special attack, B the attack, C the jump.
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
//! - Holds between the two players: walking into the other holds it as an enemy (`grab`,
//!   `grab_behind`), and it is `held` or `held_behind`, a while. The holder asks, the one held
//!   answers at its next turn (`Request`): a knee pauses it (`slam_pause`), the last knocks it
//!   down at the knee's frame; the throw lifts it over (`lift`), from which it spins in the air
//!   (`air_slam`) and falls (`air_fall`), striking as it goes; C lifts the holder itself over the
//!   one held, which it lets go; from behind, B slams it down (`slammed`, then `thrown_fall`) and
//!   C jumps back over it to hold it from the front. Held from behind, its counter throws the
//!   holder (`thrown`). Each takes its places from the other at each new frame of the hold, as
//!   its definition's `partners` give them by the other's kind.
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
    tossed,
    shaken,
    slam_pause,
    lift,
    air_slam,
    air_fall,
    slammed,
    thrown_fall,
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
    /// Tossed: it took its step ahead and down.
    tossed_on: bool = false,
    /// Its holder shook it down (`shook`): shaken, it falls (turned this way).
    shook: bool = false,
    shook_facing: ?entity.Facing = null,
    /// Whether its life has started (its first tick: it then blinks).
    started: bool = false,
    /// The ticks it still blinks: nothing strikes it.
    blink: u8 = 0,
    /// A blow it took at the last tick, which it feels now.
    taken: ?Taken = null,
    /// Its blow landed at the last tick, and the last one it landed on then.
    landed_blow: bool = false,
    landed_on: ?Handle = null,
    /// Its knee's spark is made (once a knee), or due after its move.
    knee_sparked: bool = false,
    knee_spark_due: bool = false,
    /// Its new life began at this tick, fallen out of a hole: it neither moves nor drops yet.
    fell_out: bool = false,
    /// Where it was as its turn started (a wall with no height sends it back there).
    turn_start: Vec3 = .zero,
    /// It placed the one it holds at this tick (`placeHeld`); the conveyor carried it since,
    /// this far across.
    placed_held: bool = false,
    held_carry: i8 = 0,
    /// The enemy it holds or held, drawn behind the others at its depth, and the state it held
    /// it in (`drawnBehind`).
    marked: ?Handle = null,
    marked_in: State = .fall,
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
    /// The pause in the air after a jump kick lands: its ticks.
    pause: u8 = 0,
    /// The frame of the hold it last went around the one held at.
    placed_frame: ?u8 = null,
    /// The weapon in its hand.
    weapon: ?Handle = null,
    /// The weapon its plain blow threw, while its throwing frame shows, when it is thrown again
    /// (`weaponBlow`).
    rethrown: ?Handle = null,
    /// In a hold with the other player: what the holder asked of it, which it answers at its
    /// next turn (its own tick's end forgets it); its holder's counter threw it (felt at its
    /// next tick); it lifts itself over the one it holds (not lifted by its throw); the steps
    /// of a slam; and what it showed at its tick's start (a new frame places it).
    request: Request = .none,
    countered: bool = false,
    lifting_over: bool = false,
    step: u8 = 0,
    shown: Shown = .{},
    /// Its walk's way, by the pad's directions: a walk kept out of a thing keeps it (the
    /// original numbers its walks' states by the pad, not by the move).
    way: Way = .across,
};

/// A walk's way: across only, or up or down, with a move across or not.
pub const Way = enum(u3) { across, up_across, up, down_across, down };

/// What a player holding the other asks of it: the hold turned to the front or to behind (a
/// jump over it), slammed down from behind, kneed (the last knee's knocks it down at its blow's
/// frame), lifted over by a throw. Letting go needs no asking: the hold ends.
pub const Request = enum { none, to_front, to_behind, slam, knee, last_knee, lift, toss, shake };

/// The animation, frame and facing shown.
pub const Shown = struct {
    animation: ?u8 = null,
    frame: u8 = 0,
    facing: entity.Facing = .right,
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
    slam_pause,
    lift,
    air_slam,
    air_fall,
    slammed,
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
    escape,
    air_slam,
    air_fall,
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
    /// Fallen into a hole this far down, a life is lost (none: no hole takes one).
    fall_out: ?i16 = null,
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
    /// Tossed over by an enemy holding it from the front (round 5's twins): its first frame's
    /// ticks, then a step ahead and down, its next ones'; the frame it falls at (as a throw's).
    tossed_first: u8,
    tossed_pace: u8,
    tossed_step: i16,
    tossed_drop: i16,
    tossed_falls: u8,
    /// Shaken down in a hug: its speed across, the way it faces.
    shaken_x: Fixed,
    /// Slammed down by an enemy (not the other player), its first step goes this far back too.
    slammed_enemy_back: i16,
    /// Held from behind, it is kept this far ahead of its holder.
    held_ahead: i16,
    /// Held by the other player: a knee taken pauses it these ticks; the last knee knocks it
    /// down at the holder's frame `knee_last_hits` (the holder's own number).
    slam_pause: u8,
    knee_last_hits: u8,
    /// Lifted over (by a throw, or itself over the one it holds): its first frame's ticks, each
    /// next one's, to frame `lift_ends`; then up at `lift_up`, `lift_rise` pixels higher.
    lift_first: u8,
    lift_pace: u8,
    lift_ends: u8,
    lift_up: Fixed,
    lift_rise: i16,
    /// The spin in the air: its animation's loops, its gravity and speed across; then it drops
    /// `air_slam_drop` pixels and falls at `air_fall_x` across, landing where the ground is
    /// within `air_fall_reach` pixels below its feet, `air_fall_ahead` pixels on.
    air_slam_loops: u8,
    air_slam_gravity: Fixed,
    air_slam_x: Fixed,
    air_slam_drop: i16,
    air_fall_x: Fixed,
    air_fall_reach: i16,
    air_fall_ahead: i16,
    /// Slammed down from behind: its first step's ticks, each next one's (`Tables`); then it
    /// falls back at this much more speed across, and up.
    slammed_first: u8,
    slammed_pace: u8,
    slammed_fall_back: Fixed,
    slammed_fall_up: Fixed,
    /// Holding from behind, thrown by the one held: it starts this much lower.
    countered_drop: i16,
    /// Back over the other player held after its vault, it lets go this far back.
    vault_off_step: i16,
    /// Walls are looked for this far above its feet: fallen deeper into the ground, its move
    /// across and in depth stops there; across, this far ahead of it (none: under it). Landed on
    /// a cell with no height, it is put `wall_back` back; in one after its move, it is pushed
    /// out across, `wall_push` further each way at each step (none: neither).
    wall_above: i16,
    wall_ahead: ?i16 = null,
    wall_back: ?i16 = null,
    wall_push: ?i16 = null,
    /// Armed: the frames at which the plain blow and the stab end, and the swing; the plain
    /// blow's frame at which a knife leaves the hand; a knife stabs at a thing ahead within
    /// `stab_reach` across and `stab_level` either way in depth.
    armed_blow_ends: u8,
    armed_swing_ends: u8,
    throw_frame: u8,
    stab_reach: i16,
    stab_level: i16,
};

pub const Tables = struct {
    /// The steps of a slam from behind: how far back it goes and how far down (negative: up).
    slammed_back: [4]i16,
    slammed_down: [4]i16,
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
    // The round may draw its players in front of its layers' cells from each life's start.
    if (a.tick.plan) |p| a.entity.flags.in_front = p.round.in_front.players;
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
/// tells its blow's landing at its tick `landed_at`, if it landed: its window opens then): its
/// ticks are gone through again as they went, from the state's start (its window shut). Each
/// tick the window closes a tick, the frames step, and a landing opens the window; in the first
/// blow a press is queued unless one is, and hurries the blow while the window is shut; at the
/// blow's end the queued press is taken up (the first blow again, which goes on as it was).
pub fn takeUpPresses(a: Actor, elapsed: u32, presses: []const u32, landed_at: ?u32) void {
    const n = a.numbers();
    if (a.mind.state != .attack1 or presses.len == 0) return;
    const v = a.entity.velocity;
    begin(a, a.mind.state);
    a.entity.velocity = v;
    a.mind.window = 0;
    var next: usize = 0;
    for (1..@min(elapsed, 255) + 1) |i| {
        if (a.mind.window != 0) a.mind.window -= 1;
        _ = a.step();
        if (landed_at == @as(u32, @intCast(i))) a.mind.window = n.combo_window;
        while (next < presses.len and presses[next] < i) next += 1;
        if (next < presses.len and presses[next] == i and !a.mind.queued) {
            a.mind.queued = true;
            if (a.mind.window == 0) a.retime(.attack1_hurried, if (a.frame() == 1) n.hurry_first else n.hurry_later);
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
    beginWith(a, state, null);
}

/// `begin`, with the move `own` in place of the state's (a throw that counters).
fn beginWith(a: Actor, state: State, own: ?Move) void {
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
        .grab_blow => a.startMove(own orelse .grab_blow),
        .throw => a.startMove(.throw),
        .vault => a.startMove(.vault),
        .vault_land => {
            a.animate(.vault_land);
            a.entity.move = a.kind.move_of[@backingInt(Move.vault)];
        },
        .throw_back => a.startMove(.throw_back),
        .held => a.animate(.held),
        .held_behind => a.animate(.held_behind),
        .escape => a.startMove(.escape),
        .thrown, .tossed => a.animate(.thrown),
        // Shaken in a hug, it shows its pose down (the original's state takes that animation).
        .shaken => a.animate(.down),
        .slam_pause => a.animate(.slam_pause),
        .lift => a.animate(.lift),
        .air_slam => a.startMove(.air_slam),
        .air_fall => a.startMove(.air_fall),
        // Slammed, it shows the hold's frame until its second step; its fall, the slam's.
        .slammed, .thrown_fall => {},
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
    // The state's speed: none but a walk's (set each tick by the walk), a knock-down's, which
    // goes back, and the spin's and its fall's, ahead; a jump kick keeps its speed across, a
    // slam's fall the slam's.
    const keep_x = state == .jump_kick or state == .armed_jump_kick or state == .thrown_fall;
    if (!keep_x) a.entity.velocity.x = switch (state) {
        .knocked_down => n.knocked_down_x.times(a.entity.facing.sign()),
        .dying => n.dying_x.times(a.entity.facing.sign()),
        .air_slam => n.air_slam_x.times(a.entity.facing.sign()),
        .air_fall => n.air_fall_x.times(a.entity.facing.sign()),
        else => .zero,
    };
    a.entity.velocity.depth = .zero;
    if (state != .knee and state != .grab and state != .knee_last) a.mind.knees = 0;
    a.mind.placed_frame = null;
    a.mind.jab_walk = false;
    a.mind.knee_sparked = false;
}

pub fn control(a: Actor, c: Command) void {
    const n = a.numbers();
    a.mind.turn_start = a.entity.position;
    a.mind.placed_held = false;
    a.mind.held_carry = 0;
    a.mind.shown = .{ .animation = a.entity.animation.index, .frame = a.frame(), .facing = a.entity.facing };
    defer a.mind.request = .none;
    if (!a.mind.started) {
        a.mind.started = true;
        a.mind.blink = n.blink;
        // A player's fighter never leaves the world for being far off the screen (fallen into a
        // hole, it falls on until it is out).
        a.entity.flags.stays = true;
    }
    // The combo's window closes.
    if (a.mind.window != 0) a.mind.window -= 1;
    // During a special attack it stands still, as it is.
    a.entity.flags.still = a.tick.world.special;
    if (a.tick.world.special) return leftBySpecial(a);
    if (c.pressed.special) callSpecial(a);
    feelBlow(a);
    feelCatch(a);
    if (a.mind.blink != 0) a.mind.blink -= 1;
    if (a.mind.landed_blow) spark(a);
    if (fellOut(a)) return;
    act(a, c);
    if (a.entity.velocity.height.order(n.fall_most) == .gt) a.entity.velocity.height = n.fall_most;
    if (partnerOf(a) == null) {
        goAround(a);
        placeHeld(a);
    }
    showBoxes(a);
    drawnBehind(a);
    a.mind.landed_blow = false;
    a.mind.caught = false;
}

/// The one held is drawn behind the others at its depth (a spark there shows over it): holding
/// an enemy, the player marks it, and goes on marking it in the state it held it in once it is
/// let go (a last knee's); held, it marks itself (the original's table by the player's state:
/// in the holding states the one held is marked unless a player, and kept until a state that
/// holds none; in the held ones the player itself).
fn drawnBehind(a: Actor) void {
    if (a.entity.holder != null) a.entity.flags.behind = true;
    if (a.entity.holding) |h| {
        a.mind.marked = if (a.tick.isPlayer(h)) null else h;
        a.mind.marked_in = a.mind.state;
    } else if (a.mind.state != a.mind.marked_in) a.mind.marked = null;
    const h = a.mind.marked orelse return;
    if (a.tick.world.get(h)) |e| e.flags.behind = true;
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
            if (c.pressed.attack) change(a, if (a.mind.state == .armed_jump) .armed_jump_kick else .jump_kick);
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
            if (a.mind.state == .attack1 and c.pressed.attack and !a.mind.queued) {
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
            ask(a, .last_knee);
            _ = a.step();
            kneeSpark(a);
            if (n.knee_last_leap) |from| {
                if (a.frame() < from) return;
                // The other player held lets go itself, when its knee strikes it.
                if (a.entity.holding != null and partnerOf(a) == null) a.letGo();
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
        .tossed => tossed(a),
        .shaken => shaken(a),
        .slam_pause => {
            a.mind.timer -%= 1;
            if (a.mind.timer == 0) change(a, .held);
        },
        .lift => lift(a),
        .air_slam => airSlam(a),
        .air_fall => kickGravity(a),
        .slammed => slammed(a),
        .thrown_fall => gravity(a),
    }
    if (a.mind.state == .knocked_down and a.mind.may_recover and c.pressed.jump and c.held.up) {
        a.mind.may_recover = false;
        a.mind.recovers = true;
    }
}

/// The actions open in ready, idle and walk, and at the end of a blow: a grab its reach caught,
/// the back attack, a jump, a blow (or a pick-up), else the walk by the pad.
fn choose(a: Actor, c: Command) void {
    if (a.mind.weapon != null) return armedChoose(a, c);
    if (caught(a)) return;
    if ((c.held.attack and c.pressed.jump) or (c.held.jump and c.pressed.attack)) return change(a, if (a.numbers().back_attack_up != null) .back_attack_crouch else .back_attack);
    if (c.pressed.jump) {
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
    if (!queued and !c.pressed.attack) return false;
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
    a.mind.way = if (depth < 0) (if (diagonal) .up_across else .up) else if (depth > 0) (if (diagonal) .down_across else .down) else .across;
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

/// After a jump kick lands, the kick holds still in the air a moment, its speeds kept: no move,
/// no gravity; at the pause's last tick it moves on, without gravity yet.
fn hitPause(a: Actor) bool {
    const n = a.numbers();
    if (a.mind.pause != 0) {
        a.mind.pause -= 1;
        if (a.mind.pause != 0) a.entity.flags.still = true;
        return true;
    }
    if (!a.mind.landed_blow) return false;
    a.mind.pause = n.hit_pause;
    a.entity.flags.still = true;
    return true;
}

// Taking blows ---------------------------------------------------------------------------------

/// Struck and not yet back on its feet (hurt to its recovery, thrown, dying): the special attack
/// leaves it as it is (the original's players keep a mark of it through these states).
fn struckDown(state: State) bool {
    return switch (state) {
        .hurt, .knocked_down, .down, .getting_up, .recover, .dying, .lying_dead, .thrown, .thrown_fall => true,
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
        // It faces the place of the last that struck it, as the original's reads that object's
        // place, whatever holds it now (an emptied place's across is 0).
        if (a.entity.struck_by) |h| {
            const o = &a.tick.world.entities[h.index];
            const x: i32 = if (o.alive()) o.position.x.whole() else 0;
            a.entity.facing = if (x < a.entity.position.x.whole()) .left else .right;
        }
        return die(a, null);
    }
    const t = a.mind.taken orelse return;
    a.mind.taken = null;
    const n = a.numbers();
    // It faces the place of the one who struck it, whatever holds that place now (a thrown knife
    // gone at its blow: an emptied place's across is 0), as the original reads that object.
    const o = &a.tick.world.entities[t.by.index];
    if (o.alive()) faceStriker(a, o) else a.entity.facing = if (a.entity.position.x.whole() >= 0) .left else .right;
    const knocked = t.reaction == .knock_down or a.entity.flags.airborne;
    if (knocked) a.tick.sound(fallSound(a, t.by), a.handle);
    dropWeapon(a);
    loses(a, t.by, t.damage);
    if (a.entity.health <= 0) return die(a, t.by);
    if (!knocked) a.sound(.hurt);
    letGoStruck(a);
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

/// Struck, it lets go of its hold, or is let go; but held by the other player jumping over it (a
/// throw, a throw back), it alone is freed: the other goes on over it, placed from it, as the
/// original's holder keeps its partner to its landing.
fn letGoStruck(a: Actor) void {
    if (a.entity.holder) |h| if (a.tick.actor(@This(), h)) |o| if (o.mind.state == .throw or o.mind.state == .throw_back) {
        a.entity.holder = null;
        return;
    };
    if (a.entity.holding != null or a.entity.holder != null) a.letGo();
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

/// Not on a floor (over a hole, none under its feet; or above it, a new life put there), neither
/// rising nor falling, in no state that flies: it falls, straight down from `drop`, its weapon
/// gone, a hold it was in let go.
fn ledge(a: Actor) void {
    const e = a.entity;
    if (e.flags.airborne or e.velocity.height.raw != 0 or flies(a.mind.state)) return;
    if (a.tick.onFloor(e.position)) return;
    if (e.holding != null or e.holder != null) a.letGo();
    if (a.mind.weapon) |w| {
        a.mind.weapon = null;
        a.tick.world.remove(w);
    }
    change(a, .fall);
    e.velocity.height = a.numbers().drop;
    e.flags.airborne = true;
}

/// The states in which it flies (falling, thrown, dying...), which no hole changes.
fn flies(state: State) bool {
    return switch (state) {
        .fall, .dying, .thrown_fall, .throw, .throw_back, .thrown, .tossed, .shaken, .slammed, .lift, .air_slam, .air_fall => true,
        else => false,
    };
}

/// Fallen into a hole as far as `fall_out`: a life less (none when its health had run out), its
/// cry, and its next life (or the wait to continue). True when it was.
fn fellOut(a: Actor) bool {
    const out = a.numbers().fall_out orelse return false;
    if (a.entity.position.height.whole() < out) return false;
    // TODO(PLAN item 15): round 8's balcony ends the round instead.
    if (a.entity.health != 0) lives.lose(a.tick, a.handle);
    a.sound(.death);
    const h = a.handle;
    const t = a.tick;
    lives.lifeOver(t, h);
    // Its next life stands still at its place up there at this tick (the original's start of a
    // life, its tick over at once), and walks off into its drop at the next.
    if (t.actor(@This(), h)) |next| {
        change(next, .ready);
        next.entity.velocity = .zero;
        next.entity.flags.airborne = false;
        next.entity.flags.still = true;
        next.mind.fell_out = true;
    }
    return true;
}

/// It dies: its cry, a hold let go, thrown back from the one who struck (facing it) and up, a
/// life less.
fn die(a: Actor, by: ?Handle) void {
    dropWeapon(a);
    const n = a.numbers();
    a.sound(.death);
    letGoStruck(a);
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
    // The original keeps one touch a player: a blow taken after its own landed at this tick
    // writes over it (no spark of it then, nor its combo's window or pause).
    a.mind.landed_blow = false;
    a.mind.landed_on = null;
    return true;
}

pub fn blowLanded(a: Actor, target: Handle) void {
    a.mind.landed_blow = true;
    a.mind.landed_on = target;
}

/// Its blows' landing at this tick is forgotten: no combo window, no hit pause from them.
pub fn landingCleared(a: Actor) void {
    a.mind.landed_blow = false;
    a.mind.landed_on = null;
}

/// The kind of the spark its blows make.
pub const spark_kind = "hit_spark";

/// A knee lands on the one held at its first frame with a blow (the last knee's flips it then),
/// and the one held takes it at this tick: the knee's spark at this tick, once, made after its
/// move (`moved`: the original's hold moves the holder before its spark is made).
fn kneeSpark(a: Actor) void {
    if (a.mind.knee_sparked) return;
    const f = a.currentFrame() orelse return;
    if (!f.blow) return;
    a.mind.knee_sparked = true;
    a.mind.knee_spark_due = true;
    a.mind.landed_on = a.entity.holding;
}

/// Its blow landed at the last tick: a spark at its place, by the frame it shows (its frame's
/// `spark`: small or big, ahead of it and down from its place), in the effects' first free
/// place (none free: none), never mirrored (the original's spark takes none of its facing). Facing right, a blow on one behind it makes none, but in a move
/// whose sparks go either side; facing left every one does (the original compares another
/// number than the place of the one struck then).
fn spark(a: Actor) void {
    const e = a.entity;
    const f = a.currentFrame() orelse return;
    const s: content_entity.Spark = f.spark orelse .{};
    if (!s.either_side and !e.facingLeft()) if (a.mind.landed_on) |h| if (a.other(h)) |t| {
        if (t.position.x.whole() < e.position.x.whole()) return;
    };
    const kind = a.tick.kinds.find(spark_kind) orelse return;
    const way: i32 = if (e.facingLeft()) -1 else 1;
    const places = @import("../world.zig").World.effect_places;
    const h = a.tick.world.spawnWithin(a.tick.kinds, kind, places.from, places.to, .{
        .x = .pixels(e.position.x.whole() + s.x * way),
        .depth = .pixels(e.position.depth.whole()),
        .height = .pixels(e.position.height.whole() + s.height),
    }, .right) catch return;
    a.tick.world.get(h).?.mind.hit_spark.big = s.big;
    // Drawn in front as its striker is.
    a.tick.world.get(h).?.flags.in_front = e.flags.in_front;
}

/// In the air after its move: it lands once it comes down to the ground, on its whole pixels;
/// its gravity is its state's, applied before its move (`act`).
pub fn fall(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    if (e.velocity.height.raw < 0) return;
    const reach: i16 = if (a.mind.state == .air_fall) n.air_fall_reach else 0;
    const floor = a.tick.floorUnder(e.position) orelse return;
    if (e.position.height.add(.pixels(reach)).lessThan(floor)) return;
    conveyed(a);
    offWall(a);
    a.land(.whole);
}

/// After its move, grounded or not, the walls (the original's are the level's cells, the
/// ground's among them; round 6's machines): looked for `wall_above` over its feet. Moving in
/// depth into a cell whose floor is higher (not a conveyor's), its move in depth is undone and
/// stops; a cell with a floor that high `wall_ahead` ahead across (the way it moves, right when
/// it does not) stops it: back where its turn started when that cell has no height, else its
/// move undone. Fallen deeper into the ground than its floor, the ground's cells are walls too.
/// A round without walls in depth (`depth_walls`, round 7's) has only those across.
pub fn walls(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    const looked_at = e.position.height.whole() - n.wall_above;
    const depth_walls = if (a.tick.plan) |p| p.round.depth_walls else true;
    if (depth_walls and e.velocity.depth.raw != 0) if (a.tick.floorUnder(e.position)) |under| if (looked_at > under.whole() and a.tick.carryUnder(e.position) == 0) {
        e.position.depth = e.position.depth.sub(e.velocity.depth);
        e.velocity.depth = .zero;
    };
    const reach_ahead: i32 = n.wall_ahead orelse 0;
    const way: i32 = if (e.velocity.x.raw < 0) -reach_ahead else reach_ahead;
    const ahead: fixed.Vec3 = .{ .x = e.position.x.add(.pixels(way)), .depth = e.position.depth, .height = e.position.height };
    const wall = a.tick.floorUnder(ahead) orelse return;
    if (looked_at < wall.whole()) return;
    const no_height = if (a.tick.cellAt(ahead)) |c| c.height == 0 else false;
    if (no_height) {
        e.position.x = a.mind.turn_start.x;
        e.position.depth = a.mind.turn_start.depth;
    } else {
        e.position.x = e.position.x.sub(e.velocity.x);
        e.position.depth = e.position.depth.sub(e.velocity.depth);
    }
    e.velocity.x = .zero;
    e.velocity.depth = .zero;
}

/// On a cell with no height (round 6's machines), it is put `wall_back` back across.
fn offWall(a: Actor) void {
    const back = a.numbers().wall_back orelse return;
    const e = a.entity;
    const c = a.tick.cellAt(e.position) orelse return;
    if (!c.floor or c.height != 0) return;
    e.position.x = .parts(@intCast(e.position.x.whole() - back), e.position.x.frac());
}

/// In a cell with no height after its move, it is pushed across to the nearest one with a
/// height: `wall_push` further each way at each step, ahead (right) first.
fn pushedOut(a: Actor) void {
    const step = a.numbers().wall_push orelse return;
    const e = a.entity;
    if (!noHeight(a, 0)) return;
    var by: i32 = step;
    // The original looks until it finds one; no round lacks one in a row.
    while (by < 4096) : (by += step) {
        if (!noHeight(a, by)) break;
        if (!noHeight(a, -by)) {
            by = -by;
            break;
        }
    } else return;
    e.position.x = .parts(@intCast(e.position.x.whole() + by), e.position.x.frac());
}

/// Whether the cell `dx` across from it (at or right of the round's left end) has no height.
fn noHeight(a: Actor, dx: i32) bool {
    var at = a.entity.position;
    at.x = .pixels(@max(at.x.whole() + dx, 0));
    const c = a.tick.cellAt(at) orelse return false;
    return c.height == 0;
}

/// On a conveyor's cell (round 6's), it is carried across its whole pixels a tick.
/// The one it placed at this tick is told (the original's held enemy places itself at its own
/// turn, from where its holder was carried: `heldCarry`).
fn conveyed(a: Actor) void {
    const e = a.entity;
    const by = a.tick.carryUnder(e.position);
    if (by == 0) return;
    e.position.x = e.position.x.add(.pixels(by));
    if (a.mind.placed_held) a.mind.held_carry = by;
}

/// How far across a conveyor carried it at this tick since it placed the one it holds.
pub fn heldCarry(a: Actor) i8 {
    return a.mind.held_carry;
}

pub fn landed(a: Actor) void {
    const n = a.numbers();
    switch (a.mind.state) {
        .knocked_down, .thrown_fall => {
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
        .air_fall => {
            a.entity.position.x = a.entity.position.x.add(Fixed.pixels(n.air_fall_ahead).times(a.entity.facing.sign()));
            a.sound(.land);
            change(a, if (a.mind.weapon != null) .armed_land else .land);
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
    if (a.mind.countered) return countered(a);
    if (a.entity.holding == null or a.other(a.entity.holding.?) == null) {
        a.entity.holding = null;
        // Its weapon still in hand, it stands armed.
        return change(a, if (a.mind.weapon != null) .armed_stand else .ready);
    }
    // The other player freed while it jumped over it (struck meanwhile): the hold is over.
    if (a.tick.actor(@This(), a.entity.holding.?)) |o| if (o.entity.holder == null) {
        a.entity.holding = null;
        return change(a, .ready);
    };
    a.entity.velocity.height = .zero;
    const other = partnerOf(a);
    // Holding the other player from behind, it waits while the other jumps out.
    if (other) |o| if (a.mind.state == .grab_behind and o.mind.state == .escape) return;
    if (c.pressed.jump) {
        a.sound(.jump);
        if (other != null and a.mind.state == .grab) {
            // The other player held from the front: it lifts itself over it.
            a.mind.lifting_over = true;
            a.mind.throw_ticks = a.numbers().lift_first;
            return change(a, .lift);
        }
        return change(a, if (a.mind.state == .grab_behind) .throw_back else .throw);
    }
    if (a.mind.state == .grab_behind) {
        if (c.pressed.attack) {
            ask(a, .slam);
            return change(a, .vault);
        }
    } else if (c.pressed.attack) {
        const away = (c.held.left and a.entity.facing == .right) or (c.held.right and a.entity.facing == .left);
        if (away) {
            ask(a, .lift);
            if (a.numbers().throw_turns != 0) a.entity.facing = a.entity.facing.turned();
            return change(a, .grab_blow);
        }
        a.mind.knees += 1;
        const knees = a.mind.knees;
        ask(a, if (knees >= 3) .last_knee else .knee);
        change(a, if (knees >= 3) .knee_last else .knee);
        a.mind.knees = knees;
        kneeSpark(a);
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
        ask(a, .to_behind);
        return change(a, .grab_behind);
    }
    if (!a.mind.vaulted) {
        a.mind.vaulted = true;
        ask(a, .to_front);
        return change(a, .grab);
    }
    // The other player let go, a step back from it.
    if (partnerOf(a) != null) a.entity.position.x = a.entity.position.x.add(Fixed.pixels(a.numbers().vault_off_step).times(-a.entity.facing.sign()));
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
    if (a.tick.kindOf(held).family() != .boss) {
        held.position = .{
            .x = .parts(@intCast(at.x.whole() + @as(i32, where.x) * a.entity.facing.sign()), was.x.frac()),
            .depth = .parts(@intCast(at.depth.whole()), was.depth.frac()),
            .height = .parts(@intCast(at.height.whole() + where.height), was.height.frac()),
        };
        a.mind.placed_held = true;
    }
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
    if (partnerOf(a)) |holder| return heldByPlayer(a, holder);
    if (a.mind.request == .shake) {
        const carried = a.mind.carried;
        const thrower = a.mind.thrower;
        change(a, .shaken);
        a.mind.carried = carried;
        a.mind.thrower = thrower;
        return;
    }
    if (a.mind.request == .toss) {
        const carried = a.mind.carried;
        const thrower = a.mind.thrower;
        change(a, .tossed);
        a.mind.carried = carried;
        a.mind.thrower = thrower;
        a.mind.throw_ticks = n.tossed_first;
        a.mind.tossed_on = false;
        _ = placeByHolderKind(a, "thrown");
        return;
    }
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
    const holder = partnerOf(a);
    if (holder != null) switch (a.mind.request) {
        .to_front => return change(a, .held),
        .slam => return slammedBy(a),
        else => {},
    } else if (a.mind.request == .slam) return slammedBy(a);
    if (a.mind.counter_window != 0) {
        a.mind.counter_window -= 1;
        if (a.mind.counter_window != 0 and c.pressed.attack) {
            a.mind.counter_window = 0;
            if (a.tick.turnHold(a.handle)) {
                // The throw's state with the counter's move (no sound of its own); the hold's
                // count goes on once more, on the counter's first frame.
                enter(a, .grab_blow);
                beginWith(a, .grab_blow, .counter);
                _ = a.countDown();
                return;
            }
        }
    }
    // No jump out while the other player holding it jumps over it, nor out of a hold that has
    // none (round 5's twins').
    const jumping_over = if (holder) |h| h.mind.state == .throw or h.mind.state == .throw_back else false;
    const escapable = if (a.entity.holder) |h| a.tick.holdEscapable(h) else true;
    if (c.pressed.jump and !jumping_over and escapable) {
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

/// Slammed down from behind by its holder (the other player, or an enemy): its weapon dropped,
/// by steps from the next tick, its carried damage kept.
fn slammedBy(a: Actor) void {
    const carried = a.mind.carried;
    const thrower = a.mind.thrower;
    dropWeapon(a);
    change(a, .slammed);
    a.mind.carried = carried;
    a.mind.thrower = thrower;
    a.mind.step = 0;
    a.mind.timer = a.numbers().slammed_first;
}

/// An enemy holding it asks what its hold does (`Tick.askHeld`): toss it over (9), slam it down
/// from behind (4), or shake it in a hug (11), the throw's landing costing it `damage` (taken
/// once, as the throw begins: its holder goes on asking); it answers at its next tick. The ask
/// takes the place of a blow another dealt it at this tick (the original's holder writes the
/// hit's kind over the blow's: its twin's kick on one it slams is lost, though the twin is the
/// last that touched it, whom its throw's damage counts as dealt by).
pub fn askedBy(a: Actor, holder: Handle, what: u8, damage: i16) void {
    var toucher = holder;
    if (a.entity.holder) |h| if (h.eql(holder)) if (a.mind.taken) |t| {
        a.mind.taken = null;
        toucher = t.by;
        a.mind.thrower = toucher;
    };
    if (a.mind.state != .held and a.mind.state != .held_behind) return;
    a.mind.request = switch (what) {
        9 => .toss,
        4 => .slam,
        11 => .shake,
        else => return,
    };
    a.mind.thrower = toucher;
    a.mind.carried = damage;
}

/// Its holder shakes it down (`Tick.shakeHeld`), its fall turned the holder's way when it says
/// (the original sets the side of its state, which its look takes at the fall): shaken, it falls
/// at its next tick (the mark kept until then).
pub fn shook(a: Actor, facing: ?entity.Facing) void {
    a.mind.shook = true;
    if (facing) |f| a.mind.shook_facing = f;
}

/// Shaken in an enemy's hug (round 3's boss's): freed, it stands; shaken down, it falls knocked
/// down (its weapon dropped, the hold over), `shaken_x` across the way it faces, and may land on
/// its feet; the hug's damage at its landing.
fn shaken(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    if (e.holder == null) return change(a, .ready);
    if (!a.mind.shook) return;
    a.mind.shook = false;
    const carried = a.mind.carried;
    const thrower = a.mind.thrower;
    dropWeapon(a);
    a.letGo();
    if (a.mind.shook_facing) |f| e.facing = f;
    a.mind.shook_facing = null;
    change(a, .knocked_down);
    a.mind.carried = carried;
    a.mind.thrower = thrower;
    a.mind.bounces = 0;
    e.velocity.height = n.knocked_down_up;
    e.velocity.x = n.shaken_x.times(e.facing.sign());
    e.flags.airborne = true;
    a.mind.may_recover = true;
}

/// Tossed over by an enemy holding it from the front: its first frame a while, then a step
/// ahead and down, which its holder's places undo at once (the original places the one held from
/// its holder at every tick of the hold); its next frame, then it falls ahead, knocked down, the
/// throw's damage at its landing. At each frame it is placed from its holder by its holder's kind
/// (`placeByHolderKind`).
fn tossed(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    a.mind.throw_ticks -%= 1;
    if (a.mind.throw_ticks != 0) return;
    if (a.frame() == 0 and !a.mind.tossed_on) {
        a.mind.tossed_on = true;
        e.position.x = e.position.x.add(Fixed.pixels(n.tossed_step).times(e.facing.sign()));
        e.position.height = e.position.height.add(.pixels(n.tossed_drop));
        a.mind.throw_ticks = n.tossed_pace;
        a.mind.placed_frame = null;
        _ = placeByHolderKind(a, "thrown");
        return;
    }
    if (a.frame() == n.tossed_falls) return throwFall(a);
    a.showFrame(a.frame() + 1, null);
    a.mind.throw_ticks = n.tossed_pace;
    _ = placeByHolderKind(a, "thrown");
}

/// At a new frame of what its holder does to it, placed from its holder by the places its
/// definition gives for the holder's kind (`partners`, `name`): across toward the side it faces,
/// its height from the holder's, at its depth (whole pixels, its fractions kept). False when it
/// has none for that kind.
fn placeByHolderKind(a: Actor, name: []const u8) bool {
    const h = a.entity.holder orelse return false;
    const holder = a.other(h) orelse return false;
    const pp = a.kind.definition.partnerPlaces(name, a.tick.kindOf(holder).definition.name) orelse return false;
    if (a.mind.placed_frame == a.frame()) return true;
    a.mind.placed_frame = a.frame();
    const p = pp.places[@min(a.frame(), pp.places.len - 1)];
    const e = a.entity;
    e.position.x = .parts(@intCast(holder.position.x.whole() + @as(i32, p.x) * e.facing.sign()), e.position.x.frac());
    e.position.height = .parts(@intCast(holder.position.height.whole() + p.height), e.position.height.frac());
    e.position.depth = .parts(@intCast(holder.position.depth.whole()), e.position.depth.frac());
    return true;
}

/// Thrown over its holder's head: a frame at a time, each placed from the holder; at its last,
/// it falls ahead, knocked down, the holder's blow carried to the landing.
fn thrown(a: Actor) void {
    const n = a.numbers();
    const by_player = partnerOf(a) != null;
    if (by_player) keepBlow(a);
    a.mind.throw_ticks -%= 1;
    if (a.mind.throw_ticks != 0) {
        if (!by_player) placeFromHolder(a);
        return;
    }
    if (a.frame() == n.thrown_falls) return throwFall(a);
    a.mind.throw_ticks = n.thrown_pace;
    a.showFrame(a.frame() + 1, null);
    if (!by_player) placeFromHolder(a);
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

// Holds between the two players -------------------------------------------------------------

/// The other player, when it is the one it holds or is held by (a player's behaviour).
fn partnerOf(a: Actor) ?Actor {
    const h = a.entity.holding orelse a.entity.holder orelse return null;
    return a.tick.actor(@This(), h);
}

/// It asks the other player it holds for `r`, answered at the other's next turn.
fn ask(a: Actor, r: Request) void {
    const h = a.entity.holding orelse return;
    const o = a.tick.actor(@This(), h) orelse return;
    o.mind.request = r;
}

/// The other player grabbed it (its walk's reach met its body): it feels the hold at its next
/// tick, from behind when they face the same way. Holding from behind, its hold turned by the
/// one it held: thrown by it.
pub fn heldBy(a: Actor, by: Handle) void {
    if (a.mind.state == .grab_behind) {
        a.mind.countered = true;
        return;
    }
    const o = a.other(by) orelse return;
    a.mind.caught_by = .{ .by = by, .behind = o.facing == a.entity.facing };
}

/// Held from the front by the other player: it answers what its holder asks; else after a
/// while it is free.
fn heldByPlayer(a: Actor, holder: Actor) void {
    const n = a.numbers();
    switch (a.mind.request) {
        .to_behind => return change(a, .held_behind),
        .knee => {
            loses(a, holder.handle, holderBlow(a, holder));
            if (a.entity.health <= 0) return die(a, holder.handle);
            a.sound(.hurt);
            change(a, .slam_pause);
            a.mind.timer = n.slam_pause;
            return;
        },
        .last_knee => {
            if (holder.frame() != holder.numbers().knee_last_hits) return;
            return knockedByKnee(a, holder);
        },
        .lift => {
            a.mind.lifting_over = false;
            change(a, .lift);
            a.mind.throw_ticks = n.lift_first;
            return;
        },
        else => {},
    }
    if (!a.countDown()) return;
    a.letGo();
    change(a, .ready);
}

/// The damage of the blow its holder's frame shows, or else the one it kept (`keepBlow`).
fn holderBlow(a: Actor, holder: Actor) i16 {
    const p = holder.power();
    if (p != 0) return p;
    const kept = a.mind.carried;
    a.mind.carried = 0;
    return kept;
}

/// Held by the other player, it keeps the first blow its holder's frames show, for its fall.
fn keepBlow(a: Actor) void {
    if (a.mind.carried != 0) return;
    const h = partnerOf(a) orelse return;
    a.mind.carried = h.power();
}

/// The last knee strikes: facing the holder, it takes its blow and is knocked down, let go.
fn knockedByKnee(a: Actor, holder: Actor) void {
    const n = a.numbers();
    faceStriker(a, holder.entity);
    a.sound(.hurt);
    loses(a, holder.handle, holderBlow(a, holder));
    if (a.entity.health <= 0) return die(a, holder.handle);
    dropWeapon(a);
    a.letGo();
    change(a, .knocked_down);
    a.mind.bounces = 0;
    a.entity.velocity.height = n.knocked_down_up;
    a.entity.flags.airborne = true;
}

/// Holding from behind, the one held threw it over (its counter): it is thrown from a little
/// lower, its thrower's blow kept for its landing.
fn countered(a: Actor) void {
    const n = a.numbers();
    a.mind.countered = false;
    a.entity.position.height = a.entity.position.height.add(.pixels(n.countered_drop));
    change(a, .thrown);
    a.mind.throw_ticks = n.thrown_first;
    a.mind.thrower = a.entity.holder;
    a.mind.carried = 0;
    a.mind.may_recover = false;
}

/// Lifted over the other player (its throw), or lifting itself over the one it holds: its
/// frames every few ticks to the last; then, the hold over, up and into the spin.
fn lift(a: Actor) void {
    const n = a.numbers();
    a.mind.throw_ticks -%= 1;
    if (a.mind.throw_ticks != 0) return;
    a.mind.throw_ticks = n.lift_pace;
    if (a.frame() != n.lift_ends) return a.showFrame(a.frame() + 1, null);
    a.letGo();
    a.entity.velocity.height = n.lift_up;
    a.entity.position.height = a.entity.position.height.sub(.pixels(n.lift_rise));
    a.entity.flags.airborne = true;
    change(a, .air_slam);
    a.mind.timer = n.air_slam_loops;
}

/// The spin in the air: a lighter gravity; when its animation has looped its times, it drops a
/// little and falls.
fn airSlam(a: Actor) void {
    const n = a.numbers();
    a.entity.velocity.height = a.entity.velocity.height.add(n.air_slam_gravity);
    if (!a.step() or a.frame() != 0) return;
    a.mind.timer -%= 1;
    if (a.mind.timer != 0) return;
    a.entity.position.height = a.entity.position.height.add(.pixels(n.air_slam_drop));
    change(a, .air_fall);
}

/// Slammed down from behind, by steps: up a little, shown slammed and higher (the hold over),
/// then back and down twice, shown down; then it falls back, as a knock-down does, and takes
/// the slam's blow, the screen shaking.
fn slammed(a: Actor) void {
    const n = a.numbers();
    const t = a.tables();
    keepBlow(a);
    a.mind.timer -%= 1;
    if (a.mind.timer != 0) return;
    a.mind.timer = n.slammed_pace;
    a.mind.step += 1;
    const e = a.entity;
    const back = -e.facing.sign();
    switch (a.mind.step) {
        1, 2, 3, 4 => |k| {
            if (k == 2) {
                a.letGo();
                a.animate(.slammed);
                e.velocity = .zero;
            }
            if (k == 4) a.showFrame(1, null);
            // Slammed by an enemy, its first step goes back too.
            if (k == 1) if (e.holder) |h| if (!a.tick.isPlayer(h)) {
                e.position.x = e.position.x.add(Fixed.pixels(n.slammed_enemy_back).times(back));
            };
            e.position.x = e.position.x.add(Fixed.pixels(t.slammed_back[k - 1]).times(back));
            e.position.height = e.position.height.add(.pixels(t.slammed_down[k - 1]));
            onGround(a);
        },
        else => {
            a.mind.step = 0;
            e.velocity.x = e.velocity.x.add(n.slammed_fall_back.times(back));
            e.velocity.height = n.slammed_fall_up;
            e.flags.airborne = true;
            enter(a, .thrown_fall);
            a.mind.bounces = 0;
            const c = &a.tick.world.camera;
            if (!a.tick.world.special and c.shake == 0) {
                a.tick.shake();
                a.sound(.thud);
            }
            const damage = a.mind.carried;
            a.mind.carried = 0;
            loses(a, a.mind.thrower, damage);
            if (a.entity.health <= 0) die(a, a.mind.thrower);
        },
    }
}

/// Never below the ground: there, it stands on it.
fn onGround(a: Actor) void {
    const e = a.entity;
    if (e.position.height.whole() > a.tick.world.ground.whole()) e.position.height = a.tick.world.ground;
}

/// After its move: its knee's spark, if due (`kneeSpark`). In a hold with the other player: at a
/// new frame of the hold (slammed, at each tick while held), it takes its place from the other,
/// by its definition's `partners` for the other's kind: across from the other's place toward the
/// side it faces (or the other goes the other way from it), its height from the other's, and in
/// the holds its depth (whole pixels, its fractions kept).
pub fn moved(a: Actor) void {
    if (a.mind.fell_out) a.mind.fell_out = false else ledge(a);
    // On the ground over a conveyor (round 6's), it is carried; on a cell with no height, it is
    // put back.
    if (!a.entity.flags.airborne and !a.entity.flags.landed and a.entity.velocity.height.raw == 0 and a.tick.onFloor(a.entity.position)) {
        conveyed(a);
        offWall(a);
    }
    pushedOut(a);
    if (a.mind.knee_spark_due) {
        a.mind.knee_spark_due = false;
        spark(a);
    }
    const o = partnerOf(a) orelse return;
    const name: []const u8 = switch (a.mind.state) {
        .held => "held",
        .held_behind => "held_behind",
        .slammed => "slammed",
        .throw => "vault_over",
        .throw_back => "throw_back",
        .thrown => "thrown",
        .lift => if (a.mind.lifting_over) "lift_over" else "lifted",
        else => return,
    };
    const now: Shown = .{ .animation = a.entity.animation.index, .frame = a.frame(), .facing = a.entity.facing };
    if (a.mind.state != .slammed and std.meta.eql(now, a.mind.shown)) return;
    const pp = a.kind.definition.partnerPlaces(name, o.kind.definition.name) orelse return;
    const place = pp.places[@min(a.frame(), pp.places.len - 1)];
    const e = a.entity;
    const p = o.entity;
    const dx: i32 = @as(i32, place.x) * e.facing.sign();
    if (pp.partner.moves_partner) {
        p.position.x = .parts(@intCast(e.position.x.whole() - dx), p.position.x.frac());
    } else e.position.x = .parts(@intCast(p.position.x.whole() + dx), e.position.x.frac());
    e.position.height = .parts(@intCast(p.position.height.whole() + place.height), e.position.height.frac());
    onGround(a);
    if (pp.partner.depth) e.position.depth = .parts(@intCast(p.position.depth.whole()), e.position.depth.frac());
}

/// How it may meet the other player at this tick (`systems.betweenPlayers`): not at all (0)
/// while it blinks or in a state that neither strikes nor is struck by it, its blows only (2),
/// or its blows and its grabs (1).
pub fn touchClass(a: Actor) u8 {
    if (a.mind.blink != 0) return 0;
    return switch (a.mind.state) {
        .ready, .idle, .walk, .attack1, .attack2, .attack3, .armed_stand, .armed_walk, .armed_attack, .armed_stab, .armed_swing => 1,
        .fall, .jump_crouch, .jump, .land, .jump_kick, .attack4, .back_attack, .back_attack_crouch, .back_attack_air => 2,
        .armed_jump_crouch, .armed_jump, .armed_land, .armed_jump_kick, .armed_back_attack, .armed_back_attack_crouch, .armed_back_attack_air => 2,
        .grab, .grab_behind, .escape, .lift, .air_slam, .air_fall => 2,
        else => 0,
    };
}

/// Whether the camera keeps it in its view: not in a hold's states but a back drop's, nor in a
/// throw or a lift.
pub fn keptInView(a: Actor) bool {
    return switch (a.mind.state) {
        .grab, .grab_blow, .grab_behind, .knee, .knee_last, .throw, .throw_back, .held, .held_behind, .escape, .thrown, .tossed, .shaken, .slam_pause, .lift => false,
        else => true,
    };
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
/// it calls the police car; on a lift that holds it (`Lift.holds_special`), not while the lift is
/// called, jolts or rides.
fn callSpecial(a: Actor) void {
    if (a.entity.health <= 0 or a.mind.state == .fall) return;
    if (a.tick.plan) |p| if (p.round.lift) |lf| if (lf.holds_special) {
        const l = a.tick.world.camera.lift;
        if (l.called or l.jolt != null or l.rides) return;
    };
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
/// one that stabs, else the plain blow, which throws one thrown), else the walk by the pad; its
/// weapon no longer in its hand, it is unarmed.
fn armedChoose(a: Actor, c: Command) void {
    if (caught(a)) return;
    if ((c.held.attack and c.pressed.jump) or (c.held.jump and c.pressed.attack)) return change(a, if (a.numbers().back_attack_up != null) .armed_back_attack_crouch else .armed_back_attack);
    if (c.pressed.jump) {
        a.sound(.jump);
        return change(a, .armed_jump_crouch);
    }
    if (c.pressed.attack) {
        if (pickUp(a)) return;
        const w = weaponHeld(a) orelse return change(a, .armed_attack);
        const def = a.tick.kindOf(w).definition;
        if ((def.number("swung") orelse 0) != 0) {
            a.sound(.swing_weapon);
            return change(a, .armed_swing);
        }
        if (a.mind.weapon) |wh| if (a.tick.stabs(wh)) return change(a, .armed_stab);
        if ((def.number("stabs") orelse 0) != 0 and thingAhead(a)) return change(a, .armed_stab);
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
/// A weapon whose definition says it is thrown again (`rethrown`, the pepper: the original's
/// keeps its mark of being thrown) is thrown at each tick of that frame while it lasts, the
/// throw's sound with it, to no further effect.
fn weaponBlow(a: Actor, c: Command, ends: u8) void {
    const n = a.numbers();
    const was = a.frame();
    _ = a.step();
    if (a.mind.state == .armed_attack and a.frame() == n.throw_frame) {
        if (a.frame() != was) {
            a.mind.rethrown = null;
            const w = weaponHeld(a);
            const def = if (w) |x| a.tick.kindOf(x).definition else null;
            const throws = if (def) |d| (d.number("thrown") orelse 0) != 0 else false;
            if (throws) {
                a.tick.throwWeapon(a.mind.weapon.?);
                if ((def.?.number("rethrown") orelse 0) != 0) a.mind.rethrown = a.mind.weapon;
                a.mind.weapon = null;
                a.sound(.throw_weapon);
            } else a.sound(.armed_blow);
        } else if (a.mind.rethrown) |w| {
            if (a.tick.world.get(w) != null) a.sound(.throw_weapon);
        }
    } else a.mind.rethrown = null;
    if (a.frame() == ends) choose(a, c);
}
