//! The enemies' common body: what every common enemy of the streets does besides its own way of
//! fighting (DESIGN.md W3). It is not a behaviour of its own: each kind's module (galsia.zig,
//! stalker.zig, signal.zig...) has its own named states and dispatches the common ones here.
//!
//! The common states, which every enemy's `State` names:
//! - `appear`: hidden until the round's script lets it out (its place on the screen, or the
//!   camera at its place for one that waits for the camera); then its health, its walk, the
//!   player it goes after, and it takes up the fight (its module's `fights` state);
//! - `reel`: a player's blow landed: it staggers, shaking, and takes the blow's damage at its
//!   first tick; a new blow while it reels is taken at once; a blow that knocks down, or its last
//!   health, knocks it down;
//! - `knocked_down`: it flies back from the one who struck it, bounces twice, lies a while and
//!   gets up (or, a throw, it slides first); with no health left it is knocked out;
//! - `stand`: it stands facing its target a while; during the special attack it is held still in
//!   a pose until the blast;
//! - `held`: a player holds it: it takes the hold's look, the knees' blows, and is thrown or
//!   slammed as the holder's frames say;
//! - `knocked_out`: it blinks, the player who knocked it out scores its points, and it goes;
//! - `walk_off`: it walks away from its target in depth, then paces across near it.
//!
//! A module `M` using it declares, besides what behaviours.zig asks:
//! - `Mind` with a field `body: enemy.Body`, and `State` with the common states above;
//! - `fights`, the state it takes up the fight in once out of hiding, after a reel, a knock-down,
//!   a stand or a walk off;
//! - `Animation` with `walk`, `down`, `reel`, `stand`, `thrown` and `slammed`; `Sound` with
//!   `hurt`, `thud`, `cry` and `cry_odd`; `Numbers = enemy.Numbers(struct { ...its own })`;
//! - `hurtable(state) bool`: whether a state takes the players' blows and grabs (the original's
//!   enemies test them only in the states that ask).
//!
//! Each state sets itself up at its first tick, the tick after it was entered, before the blows
//! of that tick (`begin`); the blows and grabs of a tick come before the rest of its tick
//! (`think`, systems.zig), where it stood; a state whose set-up leaves it for another ends the
//! tick there, as the original's enemies do.
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const content_entity = @import("../../content/entity.zig");
const systems = @import("../systems.zig");
const script = @import("../script.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Entity = entity.Entity;

/// How a knock-down goes on: flying (and bouncing), sliding after a throw, lying; knocked off a
/// lift, flying across before it falls.
pub const Down = enum { flying, sliding, lying, knocked_off };

/// The memory every enemy keeps for its common states.
pub const Body = struct {
    /// The state's set-up is due (its first tick).
    fresh: bool = true,
    /// It entered its state at this tick's blows or grabs (or another's tick), before its own
    /// tick: its first tick is the next.
    waits: bool = false,
    /// Its state's set-up left it for another: the rest of the tick is skipped.
    left: bool = false,
    /// The world's tick of its last tick.
    thought: u32 = std.math.maxInt(u32),
    timer: u8 = 0,
    /// The player it goes after, and the one whose blow or hold it took last.
    target: ?Handle = null,
    other: ?Handle = null,
    /// The point it walks to, and its speed toward it.
    dest_x: Fixed = .zero,
    dest_depth: Fixed = .zero,
    speed: Fixed = .zero,
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
    /// A blow that lifts (`lift`): the lift is due at the tick after the next, or under way; it
    /// reels on still once it has come down.
    lift_due: bool = false,
    lifted: bool = false,
    reel_still: bool = false,
    /// Knocked down: how it goes on, its bounces, its flight slowing.
    down: Down = .flying,
    bounces: u8 = 0,
    slowing: bool = false,
    /// Held: the holder's move it last took a blow from, a slam's ticks under way.
    hold_move: ?u8 = null,
    slam: u8 = 0,
    /// Its slam shakes the screen, from its own tick (after the camera's).
    shakes: bool = false,
    /// Knocked out: the blinks left; its knockout cry was heard.
    blinks: u8 = 0,
    cried: bool = false,
    /// Held still by the special attack: its pose (by its place across when the attack came).
    special_pose: u2 = 0,
    /// The walk off: pacing across (after its walk away in depth), on the right of its target
    /// when it began; its walks off one soon after the other, and the tick of the last.
    pacing: bool = false,
    right_side: bool = false,
    retreats: u8 = 0,
    last_walk_off: u32 = 0,
    /// Standing with no player in play: it waits for one to join.
    alone: bool = false,
    /// Its target stopped fighting (its point not taken again): back to the fight's start at its
    /// tick's end, unless its tick takes it elsewhere first.
    back_due: bool = false,
    /// Its blow landed at this tick.
    landed: bool = false,
    /// The weapon in its hand (an armed Galsia's).
    weapon: ?Handle = null,
    /// Its shutter let it out; it drops from there.
    let_out: bool = false,
    dropping: bool = false,
};

/// The numbers of the way in through a rolling shutter (`ShutterEntry`).
pub const ShutterNumbers = struct {
    /// Behind its shutter it waits this far across from it and up.
    shutter_beside: i16,
    shutter_above: i16,
    /// Let out, it drops at this speed (whole pixels, its fraction kept) in depth `shutter_depth`.
    shutter_drop: i16,
    shutter_depth: i16,
};

/// The way in through a rolling shutter (shutter.zig), for module `M` (its numbers merged with
/// `ShutterNumbers`): it puts up its shutter where it stands, facing left, and waits beside it,
/// up behind it, unseen until the shutter shows it; let out, it drops to the ground and takes up
/// the fight, placed as one that closes in.
pub fn ShutterEntry(comptime M: type) type {
    return struct {
        const A = tick.Actor(M);

        pub fn setUp(a: A) void {
            const n = a.numbers();
            const e = a.entity;
            Of(M).faceTarget(a);
            // Its walk's first frame, held while it waits (shown or not); let out, it walks.
            a.animate(.walk);
            a.pause(true);
            e.facing = .left;
            e.position.depth = .parts(0, e.position.depth.frac());
            a.tick.putUpShutter(a.handle);
            e.position.x = e.position.x.add(.pixels(n.shutter_beside));
            e.position.height = e.position.height.sub(.pixels(n.shutter_above));
            // No shadow until it lands.
            e.flags.shadowless = true;
        }

        pub fn wait(a: A) void {
            const n = a.numbers();
            const b = &a.mind.body;
            const e = a.entity;
            if (!b.let_out) return;
            if (!b.dropping) {
                b.dropping = true;
                e.velocity.height = .parts(n.shutter_drop, e.velocity.height.frac());
                a.pause(false);
                e.position.depth = .parts(n.shutter_depth, e.position.depth.frac());
            }
            e.position.height = e.position.height.add(e.velocity.height);
            const ground = a.tick.world.ground.whole();
            if (e.position.height.whole() < ground) return;
            e.position.height = .parts(@intCast(ground), e.position.height.frac());
            b.let_out = false;
            b.dropping = false;
            e.flags.shadowless = false;
            const plain: entity.Entrance = if (@hasDecl(M, "plain_entrance")) M.plain_entrance else .close_in;
            e.spawn = .{ .offset_x = e.spawn.offset_x, .offset_depth = e.spawn.offset_depth, .strength = e.spawn.strength, .entrance = plain, .colours = e.spawn.colours };
            Of(M).enter(a, M.fights);
        }

        pub fn letOut(a: A) void {
            a.mind.body.let_out = true;
        }
    };
}

/// The numbers of the common states (the original's shared code, the same for every enemy),
/// with those of a kind's own, `Own`: the struct a module declares as its `Numbers`.
pub fn Numbers(comptime Own: type) type {
    return merged(Common, Own);
}

/// The tables of the common states, with those of a kind's own: a module's `Tables`.
pub fn Tables(comptime Own: type) type {
    return merged(CommonTables, Own);
}

/// The fields of `First` then those of `Second`, as one struct.
pub fn merged(comptime First: type, comptime Second: type) type {
    const a = @typeInfo(First).@"struct";
    const b = @typeInfo(Second).@"struct";
    const n = a.field_names.len + b.field_names.len;
    var names: [n][]const u8 = undefined;
    var types: [n]type = undefined;
    for (a.field_names, a.field_types, 0..) |name, T, i| {
        names[i] = name;
        types[i] = T;
    }
    for (b.field_names, b.field_types, 0..) |name, T, i| {
        names[a.field_names.len + i] = name;
        types[a.field_names.len + i] = T;
    }
    const final_names = names;
    const final_types = types;
    return @Struct(.auto, null, &final_names, &final_types, &@splat(.{}));
}

/// The common tables, by name.
pub const CommonTables = struct {
    /// The walk off's pacing: each stretch's length, speed and frames' pace, by a draw.
    pacing: [4]u8,
    pacing_speed: [4]i32,
    pacing_pace: [4]u8,
};

/// The common numbers, by name: the extractor writes them into every enemy's definition.
pub const Common = struct {
    /// It comes out of hiding with its place this far from the view's left edge.
    appears_from: i16,
    appears_to: i16,
    /// The points the player who knocked it out scores, and the damage its blows do (its moves'
    /// too; one that loses its weapon keeps it).
    points: u32,
    power: u8,
    /// The reel's ticks, and how far a blow nudges it back.
    reel: u8,
    reel_nudge: i16,
    /// Knocked down: its speed back (with health, without), up; its flight's slowing; its
    /// bounce's most, and the slowing at each; its fall's most.
    knocked_x: Fixed,
    knocked_out_x: Fixed,
    knocked_up: Fixed,
    knocked_slowing: Fixed,
    bounce_most: Fixed,
    bounce_slowing: Fixed,
    fall_most: Fixed,
    /// Lying: each frame's ticks, the least of the drawn wait, the frame it is up at.
    lying: u8,
    lying_least: u8,
    gets_up_frame: u8,
    /// Knocked out: its blinks, the first one's ticks and each other's.
    blinks: u8,
    first_blink: u8,
    blink: u8,
    /// Standing: its ticks.
    stand: u8,
    /// Held: the ticks it reels from a knee; flipped over the holder; thrown; slammed; the
    /// height within which a player may grab it. Thrown or slammed, its body is a missile of
    /// `thrown_damage`.
    struck_held: u8,
    thrown_damage: u8,
    /// Thrown off a hold, slammed off one: the health it loses.
    thrown_hurt: u8,
    slam_hurt: u8,
    /// Knocked back as a player's new life drops in: its speeds across and up (whole pixels).
    knocked_back_x: Fixed,
    knocked_back_up: Fixed,
    flipped_x: Fixed,
    flipped_up: Fixed,
    /// Lifted in a reel: up `lift_start` pixels at once, at the speed `lift_up` (`lift_up_even`
    /// at an even tick of the game), in its knock-down's pose (or, `lift_thrown`, the pose of
    /// one thrown); down again, it reels still `lifted_reel` ticks.
    lift_start: u8,
    lift_up: Fixed,
    lift_up_even: Fixed,
    lift_thrown: u8,
    lifted_reel: u8,
    /// Knocked off a lift: its speed up then, across (whole pixels) for `knocked_off_ticks`
    /// ticks, then slower by `knocked_off_slowing` as it falls.
    knocked_off_up: Fixed,
    knocked_off_x: Fixed,
    knocked_off_ticks: u8,
    knocked_off_slowing: Fixed,
    /// Flipped over at this frame of its holder's move (a last knee's), whether its blow is
    /// under way then (Axel's, Adam's) or not (Blaze's, which leaps later).
    flipped_frame: u8,
    thrown_x: Fixed,
    thrown_up: Fixed,
    thrown_slide: u8,
    slam_ticks: u8,
    slammed_x: Fixed,
    slammed_up: Fixed,
    grab_height: i16,
    /// Held still by the special attack: its poses.
    special_spin_frame: u8,
    special_spin_turn: u8,
    special_down_frame: u8,
    special_shake_pace: u8,
    special_shake_turn: u8,
    /// The walk off: its frames' pace, its speed away in depth (faster when it walks off again
    /// soon), the depths it turns at, how soon is soon, how near it paces.
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
    /// Where the enemies walk: across from 0 to `walk_x_most`, in depth from `walk_depth_least`
    /// to `walk_depth_most`.
    walk_x_most: i16,
    walk_depth_least: i16,
    walk_depth_most: i16,
    /// The screen's middle, where its blows land and its moves start: from `middle_from` to
    /// `middle_to` pixels from the view's left edge; the players' blows land on it from
    /// `struck_from` to `struck_to`.
    middle_from: i16,
    middle_to: i16,
    struck_from: i16,
    struck_to: i16,
};

/// The common states of module `M`.
pub fn Of(comptime M: type) type {
    return struct {
        const A = tick.Actor(M);
        const State = M.State;

        /// Enters `state`; it sets itself up at its next tick.
        pub fn enter(a: A, state: State) void {
            a.mind.state = state;
            a.mind.body.fresh = true;
            a.mind.body.back_due = false;
        }

        /// The end of its tick: back to the fight's start if its target stopped fighting.
        pub fn endTick(a: A) void {
            if (!body(a).back_due) return;
            enter(a, M.fights);
        }

        /// Enters `state` at a blow or a grab of this tick, which come before its tick: it
        /// begins at the next, as the original's enemies, which take their blows at the start
        /// of their tick and leave it there.
        pub fn enterAtBlow(a: A, state: State) void {
            enter(a, state);
            a.mind.body.waits = a.mind.body.thought != a.tick.world.tick;
        }

        fn body(a: A) *Body {
            return &a.mind.body;
        }

        /// The common part of `begin`: whether the state's set-up is due (then it is no longer).
        pub fn setUpDue(a: A) bool {
            const b = body(a);
            b.left = false;
            b.landed = false;
            if (b.waits or !b.fresh) return false;
            b.fresh = false;
            return true;
        }

        /// After a set-up: whether it entered another state (the tick ends there).
        pub fn leftAt(a: A, was: State) bool {
            if (a.mind.state == was and !body(a).fresh) return false;
            body(a).left = true;
            return true;
        }

        /// A set-up that takes its whole tick: the state's own tick begins at the next.
        pub fn setUpOnly(a: A) void {
            body(a).left = true;
            body(a).landed = false;
        }

        /// The set-up of the common states.
        pub fn setUp(a: A) void {
            switch (a.mind.state) {
                .knocked_down => knockedDownSetUp(a),
                .knocked_out => knockedOutSetUp(a),
                .stand => standSetUp(a),
                .walk_off => walkOffSetUp(a),
                else => {},
            }
        }

        /// The common part of `think`: false when the tick ends here (it waits for its state's
        /// first tick, or its set-up left it for another).
        pub fn tickStarts(a: A) bool {
            const b = body(a);
            b.thought = a.tick.world.tick;
            if (!b.touched) b.touch_taken = false;
            b.touched = false;
            // It moves only where its state walks or flies (`go`, `walk`), its speed kept
            // otherwise.
            a.entity.flags.still = true;
            a.entity.flags.keeps_depth = false;
            if (b.shakes) {
                b.shakes = false;
                a.tick.shake();
            }
            if (b.waits) {
                b.waits = false;
                return false;
            }
            if (b.left or b.fresh) return false;
            return true;
        }

        /// The tick of a common state; false when the state is the kind's own.
        pub fn act(a: A) bool {
            switch (a.mind.state) {
                .appear => appear(a),
                .reel => reel(a),
                .knocked_down => knockedDown(a),
                .knocked_out => knockedOut(a),
                .held => held(a),
                .stand => standing(a),
                .walk_off => walkOff(a),
                else => return false,
            }
            return true;
        }

        // Hiding ------------------------------------------------------------------------------

        /// Hidden until the round's script lets it out; then its health, its walk, the player
        /// it goes after, and the fight. Returns whether it came out.
        pub fn appear(a: A) void {
            _ = comeOut(a);
        }

        pub fn comeOut(a: A) bool {
            a.entity.flags.hidden = true;
            if (!comesOut(a)) return false;
            a.entity.flags.hidden = false;
            a.entity.spawn.traits.waits_for_camera = false;
            // Its line: the one its colours are in as it appears (script.zig).
            if (a.entity.spawn.colours) |c| a.entity.palette = script.lineOf(a.tick, c);
            a.entity.health = a.kind.definition.health;
            a.animate(.walk);
            a.pause(false);
            if (!chooseTarget(a)) return true;
            enter(a, M.fights);
            return true;
        }

        /// Whether it comes out of hiding: its place on the screen, or for one that waits for
        /// the camera, the camera at its place.
        /// TODO(PLAN item 13): the round's script's rule (`script.comesOut`).
        fn comesOut(a: A) bool {
            const n = a.numbers();
            const x = a.entity.position.x.whole();
            const camera = a.tick.world.camera.x.whole();
            if (a.entity.spawn.traits.waits_for_camera) return camera >= x;
            const on_screen = x - camera;
            return on_screen >= n.appears_from and on_screen <= n.appears_to;
        }

        // Targets and places ------------------------------------------------------------------

        /// It picks the player it goes after: with two players in play (`Tick.fighting`), the
        /// nearer across (the second on a tie); with one, that one. With none, it stands and
        /// waits for one. Returns whether it found one.
        pub fn chooseTarget(a: A) bool {
            const w = a.tick.world;
            const found = inPlay(a);
            const first = found[0] orelse {
                body(a).target = found[1] orelse {
                    enter(a, .stand);
                    body(a).alone = true;
                    return false;
                };
                return true;
            };
            const second = found[1] orelse {
                body(a).target = first;
                return true;
            };
            const x = a.entity.position.x.whole();
            const to_first = @abs(w.getConst(first).?.position.x.whole() - x);
            const to_second = @abs(w.getConst(second).?.position.x.whole() - x);
            body(a).target = if (to_second > to_first) first else second;
            return true;
        }

        /// The players in play, by player (`Tick.fighting`).
        fn inPlay(a: A) [2]?Handle {
            return .{ a.tick.fighting(0), a.tick.fighting(1) };
        }

        pub fn target(a: A) ?*Entity {
            const h = body(a).target orelse return null;
            return a.other(h);
        }

        /// Faces `toward`'s side: right when it is to the right, else left (a tie faces left, as
        /// the original's enemies do).
        pub fn faceOf(a: A, toward: *const Entity) void {
            a.entity.facing = if (toward.position.x.whole() > a.entity.position.x.whole()) .right else .left;
        }

        /// Its walk: its own (an armed one's, weapon in hand) when it has one.
        pub fn walkOf(a: A) M.Animation {
            return if (@hasDecl(M, "walkAnimation")) M.walkAnimation(a) else .walk;
        }

        /// Faces its target.
        pub fn faceTarget(a: A) void {
            if (target(a)) |t| faceOf(a, t);
        }

        /// The one a blow or a hold on it came from: the one who struck or holds it, or who threw
        /// or swung what struck it.
        pub fn striker(a: A) ?*Entity {
            const h = body(a).other orelse return null;
            const o = a.other(h) orelse return null;
            if (o.holder) |by| return a.other(by) orelse o;
            if (o.missile) |m| return a.other(m.by) orelse o;
            return o;
        }

        /// Faces the one a blow on it came from (else its target): whether it now faces left.
        pub fn faceStriker(a: A) bool {
            if (striker(a)) |s| faceOf(a, s) else faceTarget(a);
            return a.entity.facingLeft();
        }

        /// Its point: at its target's depth, `beside` pixels from it on its own side.
        pub fn pointBeside(a: A, beside: i16) void {
            const t = target(a) orelse return;
            body(a).dest_depth = .pixels(t.position.depth.whole());
            besideTarget(a, t, beside);
        }

        /// Its point: its target's place and its own offsets (across on its own side, and in
        /// depth, turned over when it would leave the depths); false when its target is gone,
        /// and it takes up the fight again.
        pub fn pointByOffsets(a: A) bool {
            const t = target(a) orelse {
                enter(a, M.fights);
                return false;
            };
            // A target no longer a fighter (its lives gone, it waits) sends it back to the fight's
            // start at the tick's end, as the original's does; its point as it was, its state's
            // tick goes on (it walks).
            if (t.mind != .player) {
                body(a).back_due = true;
                return true;
            }
            const n = a.numbers();
            const off: i32 = a.entity.spawn.offset_depth;
            var d = t.position.depth.whole() + off;
            if (d < 0 or d >= n.walk_depth_most) d -= 2 * off;
            body(a).dest_depth = .pixels(d);
            besideTarget(a, t, a.entity.spawn.offset_x);
            return true;
        }

        fn besideTarget(a: A, t: *const Entity, beside: i16) void {
            const tx = t.position.x.whole();
            const side: i32 = if (tx < a.entity.position.x.whole()) beside else -@as(i32, beside);
            body(a).dest_x = .pixels(tx + side);
        }

        /// The speed toward its point at its speed; true when it is there, within 3 pixels both
        /// ways (its speed then left as it was).
        pub fn headForPoint(a: A) bool {
            const b = body(a);
            const dx = b.dest_x.whole() - a.entity.position.x.whole();
            const dd = b.dest_depth.whole() - a.entity.position.depth.whole();
            if (@abs(dx) < 4 and @abs(dd) < 4) return true;
            const h = fixed.heading(dx, dd, b.speed);
            a.entity.velocity.x = h.x;
            a.entity.velocity.depth = h.depth;
            return false;
        }

        /// The speed straight at its target's place, `beside` pixels short of it across (beyond
        /// it when it faces left, as the original's enemies aim).
        pub fn headForTarget(a: A, beside: i16, speed: Fixed) void {
            const t = target(a) orelse return;
            const off: i32 = if (a.entity.facingLeft()) beside else -@as(i32, beside);
            const dx = t.position.x.whole() + off - a.entity.position.x.whole();
            const dd = t.position.depth.whole() - a.entity.position.depth.whole();
            const h = fixed.heading(dx, dd, speed);
            a.entity.velocity.x = h.x;
            a.entity.velocity.depth = h.depth;
        }

        /// It walks by its speed, across and in depth, each refused at the street's limits; a
        /// solid thing in its way stops it (`Tick.keptOut`), and it walks off (anew when it
        /// walked off already). Returns false when it changed state.
        pub fn walk(a: A) bool {
            const n = a.numbers();
            const e = a.entity;
            const x = e.position.x.add(e.velocity.x);
            if (!x.lessThan(.zero) and x.lessThan(.pixels(n.walk_x_most))) e.position.x = x;
            const d = e.position.depth.add(e.velocity.depth);
            if (!d.lessThan(.pixels(n.walk_depth_least)) and d.lessThan(.pixels(n.walk_depth_most))) e.position.depth = d;
            if (!a.tick.keptOut(a.handle)) return true;
            enter(a, .walk_off);
            return false;
        }

        /// It walks by its speed in depth alone (a circle's, a line up's), refused at the
        /// street's depths; a solid thing in its way stops it, and it walks off. Returns false
        /// when it changed state.
        pub fn walkDepth(a: A) bool {
            const n = a.numbers();
            const e = a.entity;
            const d = e.position.depth.add(e.velocity.depth);
            if (!d.lessThan(.pixels(n.walk_depth_least)) and d.lessThan(.pixels(n.walk_depth_most))) e.position.depth = d;
            return unblocked(a);
        }

        /// It walks by its speed across alone, refused at the street's ends; a solid thing in its
        /// way stops it, and it walks off. Returns false when it changed state.
        pub fn walkAcross(a: A) bool {
            const n = a.numbers();
            const e = a.entity;
            const x = e.position.x.add(e.velocity.x);
            if (!x.lessThan(.zero) and x.lessThan(.pixels(n.walk_x_most))) e.position.x = x;
            return unblocked(a);
        }

        fn unblocked(a: A) bool {
            if (!a.tick.keptOut(a.handle)) return true;
            walkOffOrFight(a);
            return false;
        }

        /// In the air (a leap): across by its speed, refused at the street's ends.
        pub fn flyAcross(a: A) void {
            const n = a.numbers();
            const e = a.entity;
            const x = e.position.x.add(e.velocity.x);
            if (!x.lessThan(.zero) and x.lessThan(.pixels(n.walk_x_most))) e.position.x = x;
        }

        /// In the air: its gravity, then its fall in height; true when it is down, on the
        /// ground's whole pixels (the fraction of its height kept).
        pub fn falls(a: A) bool {
            gravity(a);
            const e = a.entity;
            e.position.height = e.position.height.add(e.velocity.height);
            const ground = a.tick.world.ground.whole();
            if (e.position.height.whole() < ground) return false;
            e.position.height = .parts(@intCast(ground), e.position.height.frac());
            return true;
        }

        /// Stopped in its walk: one walking off takes up the fight; any other walks off.
        fn walkOffOrFight(a: A) void {
            enter(a, if (a.mind.state == .walk_off) M.fights else .walk_off);
        }

        /// The damage its blows do: its own (kept from a weapon it lost), else its kind's.
        pub fn power(a: A) i16 {
            if (a.entity.power != 0) return a.entity.power;
            return a.numbers().power;
        }

        /// It takes up a new weapon of the kind named `name` (`Tick.arm`): false when no place
        /// is free for it.
        pub fn arm(a: A, name: []const u8) bool {
            body(a).weapon = a.tick.arm(a.handle, name) orelse return false;
            return true;
        }

        /// Its weapon falls from its hand.
        pub fn drop(a: A) void {
            const w = body(a).weapon orelse return;
            body(a).weapon = null;
            a.tick.dropWeapon(w);
        }

        /// It flies by its speed at this tick, across and in height (a knock-down, a throw): its
        /// depth stays, whatever its speed in depth.
        pub fn go(a: A) void {
            a.entity.flags.still = false;
            a.entity.flags.keeps_depth = true;
        }

        /// Whether its place was drawn within the screen's middle at the last tick (where its
        /// moves start); else it walks off (when `leave`).
        pub fn inMiddle(a: A) bool {
            const n = a.numbers();
            const sx = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
            return sx >= n.middle_from and sx < n.middle_to;
        }

        /// Whether it left the screen's middle: then it walks off.
        pub fn offScreen(a: A) bool {
            if (inMiddle(a)) return false;
            enter(a, .walk_off);
            return true;
        }

        /// Whether its box `box` (by its index in its definition, facing as it faces) meets its
        /// target's body.
        pub fn boxMeetsTarget(a: A, box: u8) bool {
            const t = target(a) orelse return false;
            const body_box = t.boxes.body orelse return false;
            var me = a.entity.*;
            me.boxes.mirrored = a.entity.facingLeft();
            return systems.meet(&me, &a.kind.definition.boxes[box], t, &a.tick.kindOf(t).definition.boxes[body_box]);
        }

        /// Whether the attack box of the frame it shows (a reach) meets its target's body.
        pub fn reachMeetsTarget(a: A) bool {
            const t = target(a) orelse return false;
            const box = a.entity.boxes.attack orelse return false;
            const body_box = t.boxes.body orelse return false;
            return systems.meet(a.entity, &a.kind.definition.boxes[box], t, &a.tick.kindOf(t).definition.boxes[body_box]);
        }

        /// The attack box of frame `frame` of its animation `which`.
        pub fn frameBox(a: A, which: M.Animation, frame: u8) ?u8 {
            const an = a.kind.definition.animations[a.kind.animation_of[@backingInt(which)]];
            return an.frames[frame].attack;
        }

        // Blows ------------------------------------------------------------------------------

        /// A blow meets its body. A player's blow, off the screen's middle, does not land,
        /// whatever its state (the original tests its place before the blow is its state's).
        /// Hidden, down, held, or in a state that takes no blows, it is not struck. A missile (a
        /// thrown body, a weapon) knocks it down with its damage at once. A player's blow makes
        /// it reel: the blow's damage is taken at the reel's first tick, as much as the
        /// striker's blow does then (a jab that lands on its last frame costs nothing). Reeling,
        /// a new blow is taken at once, a touch that goes on is not.
        pub fn struck(a: A, blow: tick.Blow) bool {
            const n = a.numbers();
            const b = body(a);
            if (!blow.missile) {
                const sx = a.entity.position.x.whole() - a.tick.world.camera.x.whole();
                if (sx < n.struck_from or sx >= n.struck_to) return false;
            }
            if (a.mind.state == .reel) return struckReeling(a, blow);
            if (!hurtable(a)) return false;
            if (blow.missile) {
                a.endMove();
                b.other = blow.attacker;
                a.takeDamage(blow.attacker, blow.damage);
                enterAtBlow(a, .knocked_down);
                return true;
            }
            a.endMove();
            b.other = blow.attacker;
            b.finishing = blow.reaction == .knock_down;
            b.reel_taken = false;
            b.settling = false;
            b.settle_wait = false;
            enterAtBlow(a, if (@hasDecl(M, "reels")) M.reels else .reel);
            return true;
        }

        /// Whether its state takes blows and grabs now.
        pub fn hurtable(a: A) bool {
            switch (a.mind.state) {
                .appear, .knocked_down, .knocked_out, .held => return false,
                else => return M.hurtable(a.mind.state),
            }
        }

        fn struckReeling(a: A, blow: tick.Blow) bool {
            const b = body(a);
            if (!b.reel_taken) return false;
            b.touched = true;
            // Lifted, or lifted at this tick (the original's reel takes the lift's step at once,
            // and its blow lands at each tick it touches).
            if (b.lifted or b.lift_due) return struckLifted(a, blow);
            if (b.touch_taken) return false;
            b.touch_taken = true;
            b.other = blow.attacker;
            // A missile knocks a reeling one down, its health spared.
            if (blow.missile) {
                enterAtBlow(a, .knocked_down);
                shake(a);
                return true;
            }
            if (takeReelBlow(a, blow.damage, blow.reaction == .knock_down, true)) b.settle_wait = true;
            // Knocked down, it still shakes at this tick: its knock-down starts at the next.
            if (a.mind.state == .knocked_down) shake(a);
            return true;
        }

        /// A tick of its reel shakes it (but after a lift, when it reels still).
        fn shake(a: A) void {
            if (!body(a).reel_still) a.setFrame(a.frame() ^ 1);
        }

        /// A blow taken in a reel: the health it costs; the last health, or a blow that knocks
        /// down, knocks it down; a third blow of a combo settles the reel (returns true: at the
        /// tick after the next, its pose is set and the reel starts again, without a nudge);
        /// else it is nudged back and reels on.
        fn takeReelBlow(a: A, damage: i16, finishing: bool, at_blow: bool) bool {
            const n = a.numbers();
            const b = body(a);
            a.sound(.hurt);
            a.takeDamage(b.other, damage);
            if (a.entity.health < 0 or finishing) {
                if (at_blow) enterAtBlow(a, .knocked_down) else enter(a, .knocked_down);
                return false;
            }
            // The original reads the striker's state.
            if (b.other) |o| if (a.other(o)) |s| {
                if (lifts(a, s)) {
                    b.lift_due = true;
                    return true;
                }
                if (thirdBlow(a, s)) {
                    b.settling = true;
                    return true;
                }
            };
            const back: i32 = if (a.entity.facingLeft()) 1 else -1;
            a.entity.position.x = a.entity.position.x.add(Fixed.pixels(n.reel_nudge).times(back));
            b.timer = n.reel;
            return false;
        }

        /// Whether `s` (its striker) is in its combo's third blow.
        fn thirdBlow(a: A, s: *const Entity) bool {
            const m = s.move orelse return false;
            return std.mem.eql(u8, a.tick.kindOf(s).definition.moves[m].name, "attack3");
        }

        /// Whether `s` (its striker) strikes with a blow that lifts (Adam's third: the original's
        /// reel takes the third blow to the step of the striker's character, the lift's for his).
        fn lifts(a: A, s: *const Entity) bool {
            const m = s.move orelse return false;
            return a.tick.kindOf(s).definition.moves[m].reaction == .lift;
        }

        pub fn reel(a: A) void {
            const b = body(a);
            if (!b.reel_taken) {
                b.reel_taken = true;
                b.touch_taken = true;
                b.lifted = false;
                b.lift_due = false;
                b.reel_still = false;
                _ = faceStriker(a);
                a.animate(.reel);
                a.pause(true);
                const s = if (b.other) |o| a.other(o) else null;
                // A blow that lifts lifts at once, its damage spared.
                if (s) |x| if (lifts(a, x)) return lift(a);
                // Struck by a combo's third blow, it settles first, in its pose, the blow not
                // taken: while the blow touches it still at its next tick, it is taken then.
                if (s) |x| if (thirdBlow(a, x)) {
                    b.touch_taken = false;
                    a.setFrame(2);
                    b.timer = a.numbers().reel;
                    return;
                };
                const damage = if (s) |x| a.tick.power(x) else 0;
                if (takeReelBlow(a, damage, b.finishing, false)) return;
                if (a.mind.state != .reel) return;
                b.timer -%= 1;
                return;
            }
            if (b.lifted) return lifted(a);
            if (b.settle_wait) {
                b.settle_wait = false;
                shake(a);
                return;
            }
            if (b.lift_due) {
                b.lift_due = false;
                return lift(a);
            }
            if (b.settling) {
                b.settling = false;
                a.setFrame(2);
                b.timer = a.numbers().reel;
                return;
            }
            shake(a);
            b.timer -%= 1;
            if (b.timer == 0) enter(a, M.fights);
        }

        /// The lift starts: a little up at once, facing the striker in its knock-down's pose (or
        /// one thrown's), at its speed up (the game's tick decides it); it rises from this tick.
        fn lift(a: A) void {
            const n = a.numbers();
            const b = body(a);
            b.lifted = true;
            a.entity.position.height = a.entity.position.height.sub(.pixels(n.lift_start));
            _ = faceStriker(a);
            if (n.lift_thrown != 0) {
                a.animate(.thrown);
                a.setFrame(2);
            } else a.animate(.down);
            a.pause(true);
            const up = if (a.tick.world.tick & 1 == 0) n.lift_up_even else n.lift_up;
            a.entity.velocity.height = .parts(@intCast(up.whole()), a.entity.velocity.height.frac());
            lifted(a);
        }

        /// Lifted: it rises and falls by its gravity, in height alone (its place across stays);
        /// down on the ground (at once, but in its knock-down's pose: the original's enemies fall
        /// through the air in that pose alone), it reels on still a while, in the pose of one
        /// thrown.
        fn lifted(a: A) void {
            const n = a.numbers();
            const b = body(a);
            gravity(a);
            a.entity.position.height = a.entity.position.height.add(a.entity.velocity.height);
            if (a.playing(.down) and a.entity.position.height.lessThan(a.tick.world.ground)) return;
            a.entity.position.height = .parts(@intCast(a.tick.world.ground.whole()), a.entity.position.height.frac());
            b.lifted = false;
            b.reel_still = true;
            b.timer = n.lifted_reel;
            _ = faceStriker(a);
            a.animate(.thrown);
            a.pause(true);
            a.setFrame(2);
        }

        /// A blow meets it lifted: the striker's blow lands at each tick it touches (the reel's
        /// touch going on is not taken back, as it is standing); a new touch of a blow that knocks
        /// down knocks it off the lift, its health spared: it flies across, a thrown body, from
        /// its next tick.
        fn struckLifted(a: A, blow: tick.Blow) bool {
            const n = a.numbers();
            const b = body(a);
            if (b.touch_taken or blow.reaction != .knock_down) return true;
            b.touch_taken = true;
            b.other = blow.attacker;
            b.lifted = false;
            a.entity.velocity.height = .parts(@intCast(n.knocked_off_up.whole()), a.entity.velocity.height.frac());
            a.mind.state = .knocked_down;
            b.fresh = false;
            b.waits = b.thought != a.tick.world.tick;
            b.down = .knocked_off;
            b.timer = 0;
            return true;
        }

        // Knocked down ------------------------------------------------------------------------

        /// Knocked down: it flies back from the one who struck it (farther with no health
        /// left), slowing, bounces twice, lies a while, and gets up; with no health, it is
        /// knocked out.
        pub fn knockedDownSetUp(a: A) void {
            const n = a.numbers();
            const b = body(a);
            b.down = .flying;
            b.bounces = 0;
            b.slowing = true;
            a.sound(.hurt);
            var x = n.knocked_x;
            if (a.entity.health < 0) {
                x = n.knocked_out_x;
                cry(a);
            }
            // It faces the one who struck it; with none (the special attack's blast), the
            // original reads a striker at the level's left end, and so faces left (a quirk
            // kept).
            if (striker(a)) |s| faceOf(a, s) else a.entity.facing = .left;
            a.animate(.down);
            a.pause(false);
            // Its speeds' whole pixels are set, their fractions kept from the speeds it had (the
            // original writes the whole pixels alone).
            const v = a.entity.velocity;
            const across: i32 = if (a.entity.facingLeft()) x.whole() else -x.whole();
            a.entity.velocity.x = .parts(@intCast(across), v.x.frac());
            a.entity.velocity.height = .parts(@intCast(n.knocked_up.whole()), v.height.frac());
            a.entity.flags.airborne = true;
        }

        pub fn knockedDown(a: A) void {
            const n = a.numbers();
            const b = body(a);
            switch (b.down) {
                .flying => {
                    if (!a.entity.animation.paused and a.frame() == 1) a.pause(true);
                    if (b.slowing and b.bounces == 0) slow(a, n.knocked_slowing);
                    gravity(a);
                    go(a);
                },
                .sliding => {
                    b.timer -%= 1;
                    if (b.timer == 0) return slid(a);
                    gravity(a);
                    go(a);
                },
                .lying => lie(a),
                .knocked_off => knockedOff(a),
            }
        }

        /// Knocked off a lift: at its first tick, a thrown body facing its striker, in the
        /// second pose of its knock-down, its speed across set away from the striker (its
        /// fraction kept); it flies across, its height kept, a while, then falls on as a
        /// knock-down's flight, slower across, not slowing.
        fn knockedOff(a: A) void {
            const n = a.numbers();
            const b = body(a);
            if (b.timer == 0) {
                a.sound(.hurt);
                a.entity.missile = .{ .by = b.other orelse a.handle, .damage = n.thrown_damage };
                _ = faceStriker(a);
                a.animate(.down);
                a.pause(true);
                a.setFrame(1);
                b.timer = n.knocked_off_ticks;
                const v: Fixed = .parts(@intCast(n.knocked_off_x.whole()), a.entity.velocity.x.frac());
                a.entity.velocity.x = if (a.entity.facingLeft()) v else v.neg();
            }
            a.entity.position.x = a.entity.position.x.add(a.entity.velocity.x);
            b.timer -%= 1;
            if (b.timer != 0) return;
            const v = a.entity.velocity.x;
            const slower: i32 = if (v.raw < 0) n.knocked_off_slowing.whole() else -n.knocked_off_slowing.whole();
            a.entity.velocity.x = .parts(@intCast(v.whole() + slower), v.frac());
            b.down = .flying;
            b.slowing = false;
            b.bounces = 0;
            a.entity.flags.airborne = true;
        }

        /// Lying: a while drawn at its first tick, then it gets up.
        fn lie(a: A) void {
            const n = a.numbers();
            if (a.entity.animation.paused) {
                if (a.tick.world.special) return;
                a.entity.animation.left = 2 * @as(u8, @intCast(a.pick(.lying, 4))) + n.lying_least;
                a.pause(false);
            }
            if (a.frame() == n.gets_up_frame) enter(a, M.fights);
        }

        /// A throw's slide ends: it turns, lies on its back, and flies on to its bounces.
        fn slid(a: A) void {
            faceTarget(a);
            a.entity.facing = a.entity.facing.turned();
            a.animate(.down);
            a.setFrame(2);
            body(a).down = .flying;
            body(a).slowing = false;
        }

        /// Its speed across falls toward nothing by `by` a tick.
        fn slow(a: A, by: Fixed) void {
            const v = a.entity.velocity.x;
            a.entity.velocity.x = if (v.raw < 0) v.add(by) else v.sub(by);
        }

        /// Its gravity, before it moves, up to its fall's most.
        pub fn gravity(a: A) void {
            const n = a.numbers();
            var v = a.entity.velocity.height.add(.of(a.kind.definition.gravity));
            if (!v.lessThan(n.fall_most) and v.raw >= 0) v = n.fall_most;
            a.entity.velocity.height = v;
        }

        /// In the air after its move: down on the ground or below it, it lands, rising or not,
        /// the fraction of its height kept; its gravity is applied before its move.
        pub fn fall(a: A) void {
            if (a.atGround()) a.land(.fraction_kept);
        }

        /// It landed: a knock-down bounces, slides on, or lies; a missile's flight ends.
        pub fn landed(a: A) void {
            const n = a.numbers();
            const b = body(a);
            if (a.mind.state != .knocked_down) return a.stop();
            if (b.down == .sliding) {
                a.sound(.thud);
                slid(a);
                return;
            }
            b.bounces += 1;
            if (b.bounces == 1) {
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
            if (b.bounces == 2) {
                a.sound(.thud);
                return bounce(a, a.entity.velocity.height);
            }
            b.down = .lying;
            a.entity.missile = null;
            a.pace(n.lying, n.lying);
            if (a.entity.health < 0) return enter(a, .knocked_out);
            // It lies from the tick it lands.
            lie(a);
        }

        /// A bounce: back up, a pixel a tick slower than it came down (its fraction kept, as the
        /// original turns the whole pixels alone), and slower across.
        fn bounce(a: A, down: Fixed) void {
            const n = a.numbers();
            a.entity.velocity.height = .parts(@intCast(1 - down.whole()), down.frac());
            a.entity.flags.airborne = true;
            slow(a, n.bounce_slowing);
        }

        /// The knockout cry, once: one for an even place across, another for an odd one.
        pub fn cry(a: A) void {
            const b = body(a);
            if (b.cried) return;
            b.cried = true;
            if (a.entity.position.x.whole() & 1 != 0) a.sound(.cry_odd) else a.sound(.cry);
        }

        // Knocked out ---------------------------------------------------------------------

        /// Knocked out: it lies, blinks, and goes.
        pub fn knockedOutSetUp(a: A) void {
            const n = a.numbers();
            a.animate(.down);
            a.setFrame(2);
            a.pause(true);
            body(a).blinks = n.blinks;
            body(a).timer = n.first_blink;
        }

        pub fn knockedOut(a: A) void {
            const n = a.numbers();
            const b = body(a);
            b.timer -%= 1;
            if (b.timer != 0) return;
            b.blinks -%= 1;
            if (b.blinks == 0) {
                // The one whose blow or hold it took last (or who threw or swung what struck
                // it) scores, else the player it went after.
                const by = scorer(a);
                if (by) |h| a.tick.score(h, n.points);
                return a.remove();
            }
            a.entity.flags.blinked = !a.entity.flags.blinked;
            b.timer = n.blink;
        }

        fn scorer(a: A) ?Handle {
            const b = body(a);
            if (b.other) |o| {
                if (a.tick.isPlayer(o)) return o;
                if (a.other(o)) |x| {
                    if (x.holder) |h| if (a.tick.isPlayer(h)) return h;
                    if (x.missile) |m| if (a.tick.isPlayer(m.by)) return m.by;
                }
            }
            return b.target;
        }

        // Holds ------------------------------------------------------------------------------

        /// Out of hiding, in a state that takes grabs, within its height of the one whose reach
        /// meets it.
        pub fn grabbable(a: A, by: Handle) bool {
            if (a.mind.state == .reel) {
                if (!body(a).reel_taken) return false;
            } else if (!hurtable(a)) return false;
            const n = a.numbers();
            const holder = a.other(by) orelse return false;
            return @abs(holder.position.height.whole() - a.entity.position.height.whole()) <= n.grab_height;
        }

        pub fn heldBy(a: A, holder: Handle) void {
            const b = body(a);
            // Reeling, it shook at this tick before the grab met it (the original's reel shakes,
            // then looks at its grabs; reeling still after a lift, it does not shake).
            if (a.mind.state == .reel and b.reel_taken and !b.settling) shake(a);
            a.endMove();
            b.timer = 0;
            b.other = holder;
            b.hold_move = null;
            b.slam = 0;
            enterAtBlow(a, .held);
        }

        /// Held: its look follows the hold; the holder's blows of the hold (a knee) are taken once
        /// each, and it reels while the knee lasts; the last knee's blow knocks it down off the
        /// hold.
        pub fn held(a: A) void {
            const n = a.numbers();
            const b = body(a);
            if (b.slam != 0) return slamming(a);
            const hh = a.entity.holder orelse return enter(a, M.fights);
            const holder = a.other(hh) orelse return enter(a, M.fights);
            const hk = a.tick.kindOf(holder);
            const f = a.tick.frameOf(holder);
            const m: *const content_entity.Move = if (holder.move) |i| &hk.definition.moves[i] else {
                // Held in front of the holder (facing it), or from behind.
                b.hold_move = null;
                b.timer = 0;
                return holdLook(a, holder);
            };
            if (m.reaction == .knock_down and holder.animation.frame == n.flipped_frame) {
                // Flipped over: knocked down where it is, off the hold.
                a.mind.state = .knocked_down;
                b.fresh = false;
                a.sound(.hurt);
                a.takeDamage(hh, a.tick.power(holder));
                a.tick.letGo(hh);
                faceOf(a, holder);
                a.animate(.down);
                a.pause(true);
                a.setFrame(2);
                // Its speed across: its whole pixels set, its fraction kept (the original writes
                // the word alone); up, all of it.
                const v = a.entity.velocity;
                const across: i32 = if (a.entity.facingLeft()) n.flipped_x.whole() else -n.flipped_x.whole();
                a.entity.velocity.x = .parts(@intCast(across), v.x.frac());
                a.entity.velocity.height = n.flipped_up;
                a.entity.flags.airborne = true;
                b.down = .flying;
                b.bounces = 0;
                b.slowing = false;
                return;
            }
            if (m.reaction == .reel and m.damage != 0) {
                if (b.hold_move != holder.move) {
                    b.hold_move = holder.move;
                    a.sound(.hurt);
                    a.takeDamage(hh, a.tick.power(holder));
                    if (a.entity.health < 0) {
                        enter(a, .knocked_down);
                        a.tick.letGo(hh);
                        return;
                    }
                    faceOf(a, holder);
                    a.animate(.reel);
                    a.pause(true);
                    a.setFrame(2);
                    b.timer = n.struck_held;
                }
                if (b.timer == 0) return;
                a.setFrame(a.frame() ^ 1);
                b.timer -= 1;
                if (b.timer == 0) {
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
        fn holdLook(a: A, holder: *const Entity) void {
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

        /// The hold let it go, at the holder's frame then: thrown, it flies off with the throw's
        /// damage taken, a missile until it lies; slammed, it is slammed down there, and knocked
        /// down a moment later; else it takes up the fight again.
        pub fn letGoBy(a: A, holder: Handle) void {
            const n = a.numbers();
            const b = body(a);
            // A hold it left itself (flipped over, knocked out) ends without more.
            if (a.mind.state != .held) return;
            // Let go during its holder's tick, which comes before its own: its next state
            // begins at its next tick.
            b.waits = b.thought != a.tick.world.tick;
            const h = a.other(holder) orelse return enter(a, M.fights);
            const hk = a.tick.kindOf(h);
            const move: ?*const content_entity.Move = if (h.move) |m| &hk.definition.moves[m] else null;
            const f = a.tick.frameOf(h);
            const lets_go = f != null and f.?.held != null and f.?.held.?.lets_go;
            if (move == null or !lets_go) {
                if (a.mind.state == .held) enter(a, M.fights);
                return;
            }
            const m = move.?;
            switch (m.reaction) {
                .thrown => {
                    a.animate(.thrown);
                    a.pause(true);
                    a.setFrame(1);
                    // Its speeds: the throw's push (its holder's: Blaze throws farther), or its own.
                    const away: i32 = if (a.entity.position.x.lessThan(h.position.x)) -1 else 1;
                    a.entity.velocity.x = (if (m.push_x != 0) Fixed.of(m.push_x) else n.thrown_x).times(away);
                    a.entity.velocity.height = if (m.push_height != 0) Fixed.of(m.push_height) else n.thrown_up;
                    a.entity.flags.airborne = true;
                    a.takeDamage(holder, n.thrown_hurt);
                    b.down = .sliding;
                    b.timer = n.thrown_slide;
                    b.bounces = 0;
                    b.slowing = false;
                    a.mind.state = .knocked_down;
                    b.fresh = false;
                    a.entity.missile = .{ .by = holder, .damage = n.thrown_damage };
                },
                .slammed => {
                    a.sound(.thud);
                    b.shakes = true;
                    b.slam = n.slam_ticks;
                    b.other = holder;
                    b.hold_move = h.move;
                    slamming(a);
                },
                else => if (a.mind.state == .held) enter(a, M.fights),
            }
        }

        /// Slammed down: a moment later, knocked down with the slam's damage, flying back.
        fn slamming(a: A) void {
            const n = a.numbers();
            const b = body(a);
            b.slam -%= 1;
            if (b.slam != 0) return;
            const by = b.other;
            a.takeDamage(by, n.slam_hurt);
            b.down = .flying;
            b.bounces = 0;
            b.slowing = false;
            // It flies in the slam's last pose.
            a.pause(true);
            a.entity.velocity.x = if (a.entity.facingLeft()) n.slammed_x else n.slammed_x.neg();
            a.entity.velocity.height = n.slammed_up;
            a.entity.flags.airborne = true;
            a.mind.state = .knocked_down;
            b.fresh = false;
            if (by) |x| a.entity.missile = .{ .by = x, .damage = n.thrown_damage };
            // It flies from this tick.
            knockedDown(a);
        }

        // Standing ---------------------------------------------------------------------------

        /// It stands, facing its target, a while (with no player in play, until one comes).
        /// During the special attack it is held still in a pose by its place across: turning
        /// about now and then, lying, or shaking on its feet.
        pub fn standSetUp(a: A) void {
            const n = a.numbers();
            const b = body(a);
            if (!a.tick.world.special) {
                if (b.alone) return a.pause(true);
                a.animate(.stand);
                a.pause(false);
                faceTarget(a);
                b.timer = n.stand;
                return;
            }
            switch (b.special_pose) {
                0 => {
                    faceTarget(a);
                    a.animate(.thrown);
                    a.pause(true);
                    a.setFrame(n.special_spin_frame);
                    b.timer = n.special_spin_turn;
                },
                1, 3 => {
                    a.entity.facing = .right;
                    a.animate(.down);
                    a.pause(true);
                    a.setFrame(n.special_down_frame);
                },
                2 => {
                    faceTarget(a);
                    a.animate(.walk);
                    a.pause(false);
                    a.pace(n.special_shake_pace, n.special_shake_pace);
                    b.timer = n.special_shake_turn;
                },
            }
        }

        pub fn standing(a: A) void {
            const n = a.numbers();
            const b = body(a);
            if (!a.tick.world.special) {
                if (b.alone) {
                    const players = inPlay(a);
                    if (players[0] == null and players[1] == null) return;
                    b.alone = false;
                    return enter(a, M.fights);
                }
                b.timer -%= 1;
                if (b.timer == 0) enter(a, M.fights);
                return;
            }
            if (b.special_pose & 1 != 0) return;
            b.timer -%= 1;
            if (b.timer != 0) return;
            b.timer = if (b.special_pose == 0) n.special_spin_turn else n.special_shake_turn;
            a.entity.facing = a.entity.facing.turned();
        }

        // Walking off ------------------------------------------------------------------------

        /// The walk off: it walks away from its target in depth (faster when it walks off again
        /// soon, and then every other time the other way), to the depths' far bands; then it
        /// paces across near its target, a stretch at a time, each of a drawn length and speed,
        /// until it is no longer near it, and takes up the fight again.
        pub fn walkOffSetUp(a: A) void {
            const n = a.numbers();
            const b = body(a);
            const t = target(a) orelse return;
            // An armed one walks off as it was, its weapon in hand: its look kept.
            if (!@hasDecl(M, "walks_off_as_it_was") or !M.walks_off_as_it_was) {
                faceOf(a, t);
                a.animate(.walk);
            }
            a.pause(false);
            a.pace(n.walk_off_pace, 1);
            b.right_side = !a.entity.position.x.lessThan(t.position.x);
            b.pacing = false;
            a.entity.velocity.x = .zero;
            var v = n.walk_off_depth;
            if (b.retreats >= n.walk_off_faster_after) v = n.walk_off_faster;
            if (b.retreats >= n.walk_off_fastest_after) v = n.walk_off_fastest;
            const up = if (@hasDecl(M, "walks_off_down") and M.walks_off_down) false else t.position.depth.whole() >= n.walk_off_up_from;
            if (up) v = v.neg();
            a.entity.velocity.depth = v;
            const now = a.tick.world.tick;
            if (now -% b.last_walk_off < n.walk_off_again) {
                if (b.retreats & 1 == 0) a.entity.velocity.depth = a.entity.velocity.depth.neg();
                b.retreats +%= 1;
            } else {
                b.retreats = 0;
            }
            b.last_walk_off = now;
        }

        pub fn walkOff(a: A) void {
            const n = a.numbers();
            const b = body(a);
            const t = target(a) orelse return enter(a, M.fights);
            faceOf(a, t);
            if (!b.pacing) {
                const d = a.entity.position.depth.whole();
                const away = if (a.entity.velocity.depth.raw >= 0) d > n.walk_off_down_to else d < n.walk_off_up_to;
                if (!away) {
                    _ = walk(a);
                    return;
                }
                b.pacing = true;
                b.timer = 0;
            }
            if (b.timer == 0) return pace(a);
            b.timer -= 1;
            const near = if (a.entity.velocity.x.raw >= 0)
                t.position.x.whole() + n.walk_off_near > a.entity.position.x.whole()
            else
                !(t.position.x.whole() - n.walk_off_near > a.entity.position.x.whole());
            if (!near) return enter(a, M.fights);
            // Across only.
            const x = a.entity.position.x.add(a.entity.velocity.x);
            if (!x.lessThan(.zero) and x.lessThan(.pixels(n.walk_x_most))) a.entity.position.x = x;
            if (a.tick.keptOut(a.handle)) enter(a, M.fights);
        }

        /// A new stretch of pacing: its ticks and its speed drawn, away from the target's side.
        fn pace(a: A) void {
            const t = a.tables();
            const b = body(a);
            b.timer = t.pacing[a.pick(.pacing, 4)];
            const k = a.pick(.pacing_speed, 4);
            var v: Fixed = .of(t.pacing_speed[k]);
            if (b.right_side) v = v.neg();
            a.entity.velocity.x = v;
            a.pace(t.pacing_pace[k], 1);
        }

        // Knocked back -------------------------------------------------------------------------

        /// A player's new life drops in while it is on the screen (Tick.knockBack): it is knocked
        /// back where it stands, flying across and up (its speeds' whole pixels set, their
        /// fractions kept), facing left, without the knock-down's set-up: its health and its
        /// sound spared. Knocked out, or waiting to come in, it stays as it is.
        pub fn knockedBack(a: A) void {
            const n = a.numbers();
            const b = body(a);
            if (a.mind.state == .knocked_out) return;
            if (@hasField(M.State, "shutter_entry") and a.mind.state == .shutter_entry) return;
            if (@hasField(M.State, "enter") and a.mind.state == .enter) return;
            a.endMove();
            a.entity.animation.pace = null;
            a.mind.state = .knocked_down;
            b.fresh = false;
            b.waits = false;
            b.down = .flying;
            b.bounces = 0;
            b.slowing = false;
            a.entity.facing = .left;
            // Its knock-down's frames from the first, the first's ticks those left of the frame
            // it showed (the original sets the frame, not its count).
            const left = a.entity.animation.left;
            a.animate(.down);
            a.entity.animation.left = left;
            a.pause(false);
            const v = a.entity.velocity;
            a.entity.velocity.x = .parts(@intCast(n.knocked_back_x.whole()), v.x.frac());
            a.entity.velocity.height = .parts(@intCast(n.knocked_back_up.whole()), v.height.frac());
            a.entity.flags.airborne = true;
        }

        // The special attack -----------------------------------------------------------------

        /// A player called the special attack while it is on the screen: it stands still, its
        /// health gone, until the blast.
        pub fn specialCalled(a: A) void {
            switch (a.mind.state) {
                .appear, .knocked_out => return,
                else => {},
            }
            // Held, it stays so: its holder lets it go when the special attack's run leaves the
            // holder behind (player.zig).
            a.endMove();
            // The last whose blow or hold it took is the one the traces name.
            const by = body(a).other;
            body(a).other = null;
            a.takeDamage(by, a.entity.health + 1);
            body(a).special_pose = @intCast(a.entity.position.x.whole() & 3);
            enter(a, .stand);
        }

        /// The special attack knocks it down, as `how` says (tick.zig's `SpecialFall`), its blow
        /// `by`'s: one in its knock-down's pose only at the frame its pose stays on, and only
        /// in the last pass; below the line only.
        pub fn specialKnockedDown(a: A, by: ?Handle, how: tick.Tick.SpecialFall) bool {
            const falling = a.plays(.down);
            switch (how) {
                .line => |line| if (falling or a.entity.position.depth.whole() <= line) return false,
                .rest => |frame| if (falling and a.frame() != frame) return false,
                .any => {},
            }
            a.endMove();
            body(a).other = by;
            enterAtBlow(a, .knocked_down);
            return true;
        }

        // Taken up from a situation -----------------------------------------------------------

        /// Taken up in its state from a situation another program recorded, `elapsed` ticks
        /// after it entered it (its set-up at the tick after): knocked out, its blinks counted
        /// down by then; reeling, its blow taken and its reel gone on since; in a state its
        /// module says counts down every tick (`countdowns`), set up now (from its walk, which a
        /// set-up that pauses keeps) and its count gone down by the ticks since; another, set up
        /// at its next tick.
        pub fn takeUp(a: A, elapsed: u32) void {
            if (elapsed >= 1 and @hasDecl(M, "countdowns")) {
                for (M.countdowns) |st| if (a.mind.state == st) {
                    takeUpTarget(a);
                    const v = a.entity.velocity;
                    body(a).fresh = true;
                    body(a).waits = false;
                    a.animate(walkOf(a));
                    M.begin(a);
                    body(a).timer -|= @intCast(@min(elapsed, 255));
                    takeUpOffsets(a, v);
                    return;
                };
            }
            takeUpTarget(a);
            // Behind its shutter (which shows it and finds it, shutter.zig): set up already; let
            // out, it drops.
            if (@hasField(M.State, "shutter_entry") and a.mind.state == .shutter_entry and elapsed >= 1) {
                const b = body(a);
                b.fresh = false;
                a.animate(.walk);
                // Its walk held while it waits; dropping, it walks.
                a.pause(true);
                if (a.entity.velocity.height.raw > 0) {
                    b.let_out = true;
                    b.dropping = true;
                    a.pause(false);
                }
                return;
            }
            switch (a.mind.state) {
                .appear => {
                    a.entity.flags.hidden = true;
                    a.animate(.walk);
                },
                .knocked_out => {
                    const n = a.numbers();
                    const b = body(a);
                    knockedOutSetUp(a);
                    b.fresh = false;
                    var k: u32 = 0;
                    while (k < elapsed) : (k += 1) {
                        b.timer -%= 1;
                        if (b.timer != 0) continue;
                        if (b.blinks > 1) b.blinks -= 1;
                        a.entity.flags.blinked = !a.entity.flags.blinked;
                        b.timer = n.blink;
                    }
                },
                .knocked_down => if (elapsed >= 1) takeUpDown(a) else {
                    body(a).fresh = true;
                },
                // Reeling since its first tick at least: the blow taken then, its frame turned and
                // its count down at each tick since.
                .reel => if (elapsed >= 1) {
                    const b = body(a);
                    b.fresh = false;
                    b.reel_taken = true;
                    b.touch_taken = false;
                    a.animate(.reel);
                    a.pause(true);
                    a.setFrame(@intCast((elapsed - 1) & 1));
                    b.timer = a.numbers().reel -| @as(u8, @intCast(@min(elapsed, 255)));
                } else {
                    body(a).fresh = true;
                    if (a.entity.animation.index == null) a.animate(.walk);
                },
                else => {
                    body(a).fresh = true;
                    // One that walks off as it was shows its walk then (an armed one's).
                    const as_it_was = @hasDecl(M, "walks_off_as_it_was") and M.walks_off_as_it_was;
                    const walks_off = @hasField(M.State, "walk_off") and a.mind.state == .walk_off;
                    if (walks_off and as_it_was) {
                        a.animate(walkOf(a));
                    } else if (a.entity.animation.index == null) a.animate(.walk);
                    // Walking off since its first tick at least: set up then (its pace, its
                    // side), at the speed it has.
                    if (walks_off and elapsed >= 1) {
                        const v = a.entity.velocity;
                        body(a).waits = false;
                        M.begin(a);
                        a.entity.velocity = v;
                        body(a).last_walk_off = a.tick.world.tick -% elapsed;
                    }
                },
            }
        }

        /// Taken up knocked down since its first tick at least: on the ground, come down from
        /// its last bounce (it would be going back up from another), it lies; else it flies on
        /// (its bounces taken up apart).
        fn takeUpDown(a: A) void {
            const n = a.numbers();
            const b = body(a);
            b.fresh = false;
            b.slowing = true;
            b.cried = a.entity.health < 0;
            a.animate(.down);
            _ = n;
            if (a.atGround() and a.entity.velocity.height.raw >= 0) return takeUpLying(a);
            b.down = .flying;
            a.entity.flags.airborne = true;
        }

        /// Taken up lying after its last bounce.
        fn takeUpLying(a: A) void {
            const n = a.numbers();
            const b = body(a);
            b.down = .lying;
            b.bounces = 3;
            a.entity.missile = null;
            a.entity.flags.airborne = false;
            a.pace(n.lying, n.lying);
            a.pause(false);
        }

        /// Taken up showing its frame `shown` ticks, its speed what it is since `ago` ticks with
        /// `draws` the last draws by then. Knocked down: in the air it holds its frames from its
        /// second; lying on the frame it landed on, that frame shows the while drawn as it landed
        /// (counted from that tick). True when it took up the frame's ticks left itself.
        pub fn takeUpFrame(a: A, shown: u32, ago: u32, draws: []const u16) bool {
            if (a.mind.state != .knocked_down) return false;
            const b = body(a);
            if (b.down == .flying) {
                a.pause(a.frame() >= 1);
                return false;
            }
            if (shown <= ago or draws.len == 0) return false;
            const drawn: u32 = 2 * @as(u32, draws[0] & 3) + a.numbers().lying_least;
            a.setTicksLeft(@intCast(@max(1, @min(255, drawn -| (ago + 1)))));
            return true;
        }

        /// Taken up holding the weapon `w`.
        pub fn takeUpWeapon(a: A, w: Handle) void {
            body(a).weapon = w;
        }

        /// Taken up reeling, a blow taken `ago` ticks before: its reel started again then, and the
        /// blow touches it still while its striker is in the state it struck in.
        pub fn takeUpStruck(a: A, ago: u32, striking: bool) void {
            const b = body(a);
            if (a.mind.state != .reel or !b.reel_taken) return;
            b.timer = a.numbers().reel -| @as(u8, @intCast(@min(ago + 1, 255)));
            b.touch_taken = striking;
        }

        /// Taken up walking off at a speed across: it paces, its stretch begun when that speed
        /// came, its length by the first of the draws then when the second gives that speed
        /// (they were its own), on the side its speed leaves.
        pub fn takeUpCourse(a: A, ago: u32, draws: []const u16) void {
            // Knocked down, on the ground, its speed unchanged a tick at least (in the air its
            // gravity changes it every tick): it lies (its speeds as its last landing left them).
            if (a.mind.state == .knocked_down and body(a).down == .flying and ago >= 1 and a.atGround()) return takeUpLying(a);
            // Entered at the situation's tick, its set-up still due, its speed is its last state's.
            if (a.mind.state != .walk_off or a.entity.velocity.x.raw == 0 or body(a).fresh) return;
            const b = body(a);
            b.fresh = false;
            b.pacing = true;
            b.right_side = a.entity.velocity.x.raw < 0;
            if (!@hasDecl(M, "walks_off_as_it_was") or !M.walks_off_as_it_was) a.animate(walkOf(a));
            a.pause(false);
            const t = a.tables();
            b.timer = 1;
            const speed = @abs(a.entity.velocity.x.raw);
            if (draws.len >= 2 and t.pacing_speed[draws[1] & 3] == speed) {
                b.timer = t.pacing[draws[0] & 3] -| @as(u8, @intCast(@min(ago, 255)));
                a.pace(t.pacing_pace[draws[1] & 3], 1);
                return;
            }
            // Without its draws, its frames' pace is its speed's.
            for (t.pacing_speed, 0..) |s, k| if (s == speed) {
                a.pace(t.pacing_pace[k], 1);
                return;
            };
        }

        /// Taken up held: its holder's move under way was taken already; held since a tick at
        /// least, its hold's set-up was done then.
        pub fn takeUpHeld(a: A, elapsed: u32) void {
            const hh = a.entity.holder orelse return;
            const holder = a.other(hh) orelse return;
            body(a).hold_move = holder.move;
            if (elapsed == 0) return;
            body(a).fresh = false;
            body(a).waits = false;
            if (holder.move == null) holdLook(a, holder);
        }

        /// Taken up, it bounced `times` times in its fall.
        pub fn takeUpBounces(a: A, times: u8) void {
            body(a).bounces = times;
        }

        /// Its place beside its target in depth may have been turned over since its record (a
        /// wait not level with its target turns it): heading at speed `v` (the trace's, from
        /// its place before its last move), it heads for the side that speed tells.
        fn takeUpOffsets(a: A, v: fixed.Vec3) void {
            if (v.x.raw == 0 and v.depth.raw == 0) return;
            const t = target(a) orelse return;
            const was = a.entity.position.sub(.{ .x = v.x, .depth = v.depth });
            for (0..2) |_| {
                const off: i32 = a.entity.spawn.offset_depth;
                var d = t.position.depth.whole() + off;
                if (d < 0 or d >= a.numbers().walk_depth_most) d -= 2 * off;
                const side: i32 = if (t.position.x.whole() < was.x.whole()) a.entity.spawn.offset_x else -@as(i32, a.entity.spawn.offset_x);
                const h = fixed.heading(t.position.x.whole() + side - was.x.whole(), d - was.depth.whole(), body(a).speed);
                if (h.x.raw == v.x.raw and h.depth.raw == v.depth.raw) return;
                a.entity.spawn.offset_depth = -a.entity.spawn.offset_depth;
            }
        }

        /// Taken up out of hiding: the one whose blow it took last, and the player it goes after
        /// (chosen now, its state kept, when the situation did not say).
        fn takeUpTarget(a: A) void {
            if (a.mind.state == .appear) return;
            body(a).other = a.entity.struck_by;
            if (body(a).target != null) return;
            const was = a.mind.state;
            const fresh = body(a).fresh;
            _ = chooseTarget(a);
            a.mind.state = was;
            body(a).fresh = fresh;
            body(a).alone = false;
        }
    };
}
