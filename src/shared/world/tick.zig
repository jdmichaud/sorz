//! A logic tick's context: the world, its kinds, the random generator, the pads and the tick's
//! output, with what the systems and the behaviours share (DESIGN.md W3, W4): an entity's
//! behaviour reached through its hooks, and the `Actor` a behaviour acts through.
//!
//! An actor is an entity seen by its behaviour `M` (behaviours.zig): its fields, its kind, its
//! memory typed as `M.Mind`, and the behaviour's names typed as `M` declares them
//! (`a.animate(.walk)`, `a.startMove(.punch)`, `a.numbers().reach`, `a.sound(.hurt)`), each
//! bound to the definition's data when the kinds were bound (kinds.zig).
const std = @import("std");
const input = @import("../input.zig");
const content_entity = @import("../content/entity.zig");
const content_round = @import("../content/round.zig");
const fixed = @import("fixed.zig");
const random = @import("random.zig");
const entity = @import("entity.zig");
const kinds_mod = @import("kinds.zig");
const world_mod = @import("world.zig");
const output = @import("output.zig");
const behaviours = @import("behaviours.zig");
const systems = @import("systems.zig");
const script = @import("script.zig");
const lives = @import("lives.zig");

const Fixed = fixed.Fixed;
const Vec3 = fixed.Vec3;
const Entity = entity.Entity;
const Handle = entity.Handle;
const Kind = kinds_mod.Kind;
const Kinds = kinds_mod.Kinds;
const World = world_mod.World;
const Command = world_mod.Command;
const Output = output.Output;
const capacity_ = entity.capacity;

/// The pads of a logic tick, as read at two display ticks in play, in their order: the last
/// logic tick's second, and its own first (schedule.zig; the systems' `commands` says how a
/// player reads them).
pub const Input = struct {
    pads: [2]input.Pads = .{ .{}, .{} },
    /// A player who joins the game under way at this tick (lives.zig `join`).
    join: ?Join = null,

    /// The same pads at both display ticks.
    pub fn steady(pads: input.Pads) Input {
        return .{ .pads = .{ pads, pads } };
    }
};

/// A player joining the game under way: who, as which kind, with how many lives (the one it
/// plays counted).
pub const Join = struct { player: u1, kind: entity.KindId, lives: u8, colours: ?u8 = null };

/// A blow that meets an entity's body (at the struck one's turn, systems.zig).
pub const Blow = struct {
    attacker: Handle,
    damage: i16,
    reaction: content_entity.Reaction,
    /// The speed it gives: across, away from the attacker, and in height.
    push: Vec3,
    /// A missile's (a body thrown, a weapon): it knocks down with its damage at once.
    missile: bool = false,
};

/// A frame asked past the last of its animation (a rule gone wrong): a test fails on it, naming
/// the kind, the animation and the state; the game tells it once and shows the last frame.
fn frameOutside(kind: []const u8, animation: []const u8, state: []const u8, index: u8, frames: usize) void {
    if (@import("builtin").is_test) std.debug.panic("{s}: frame {d} of its animation {s} ({d} frames), in its state {s}", .{ kind, index, animation, frames, state });
    if (frame_outside_told) return;
    frame_outside_told = true;
    std.log.warn("{s}: frame {d} of its animation {s} ({d} frames), in its state {s}: its last shown", .{ kind, index, animation, frames, state });
}
var frame_outside_told = false;

pub const Tick = struct {
    world: *World,
    kinds: *const Kinds,
    random: *random.Random,
    out: *Output,
    input: Input = .{},
    /// The round's script the world follows (null: none, a world of the tests or the screens).
    plan: ?*const script.Plan = null,
    /// The original's mode of play, where its objects take shadows' places (shadows.zig): not a
    /// round's load (but the attract demo's).
    play_mode: bool = true,

    pub fn kindOf(t: *const Tick, e: *const Entity) *const Kind {
        return t.kinds.get(e.kind.?);
    }

    /// A number drawn for `purpose`, noted in the tick's draws.
    pub fn draw(t: *Tick, comptime purpose: random.Purpose) u16 {
        return t.random.draw(purpose, &t.out.draws);
    }

    pub fn pick(t: *Tick, comptime purpose: random.Purpose, comptime n: u16) u16 {
        return t.random.pick(purpose, n, &t.out.draws);
    }

    /// Asks for the sound `name` of the sound content.
    pub fn sound(t: *Tick, name: []const u8, by: ?Handle) void {
        t.out.sounds.append(.{ .name = name, .by = by });
    }

    /// Starts move `index` of `e`'s kind: its animation from the first frame, its sound.
    pub fn startMove(t: *Tick, h: Handle, e: *Entity, index: u8) void {
        const m = t.kindOf(e).definition.moves[index];
        e.move = index;
        e.flags.plain_blows = false;
        t.startAnimation(h, e, m.animation);
        if (m.sound) |s| t.sound(s, h);
    }

    /// Starts animation `index` of `e`'s kind from its first frame, and asks for that frame's
    /// sound.
    pub fn startAnimation(t: *Tick, h: Handle, e: *Entity, index: u8) void {
        t.kinds.startAnimation(e, index);
        t.frameStarts(h, e);
    }

    /// The frame `e` is on starts showing: its sound is asked for.
    pub fn frameStarts(t: *Tick, h: Handle, e: *const Entity) void {
        t.out.new_frames[h.index] = true;
        const f = t.frameOf(e) orelse return;
        if (f.sound) |s| t.sound(s, h);
    }

    /// The frame of its animation `e` is on, if any.
    pub fn frameOf(t: *const Tick, e: *const Entity) ?*const content_entity.Frame {
        const index = e.animation.index orelse return null;
        return &t.kindOf(e).definition.animations[index].frames[e.animation.frame];
    }

    /// The damage `e`'s blow does at this tick: its move's, while the frame it shows has the
    /// blow under way; 0 otherwise.
    pub fn power(t: *const Tick, e: *const Entity) i16 {
        const m = e.move orelse return 0;
        const f = t.frameOf(e) orelse return 0;
        if (!f.blow) return 0;
        if (e.power != 0) return e.power;
        return std.math.cast(i16, t.kindOf(e).definition.moves[m].damage) orelse std.math.maxInt(i16);
    }

    /// `target` takes `damage` from `attacker` (null: no entity's, the special attack's): its
    /// health falls, and the blow is noted for the traces.
    pub fn takeDamage(t: *Tick, target: Handle, attacker: ?Handle, damage: i16) void {
        const e = t.world.get(target) orelse return;
        e.health -|= damage;
        if (attacker) |a| e.struck_by = a;
        t.out.hits.append(.{ .attacker = attacker, .target = target, .damage = damage });
    }

    /// `h`'s behaviour seen as module `M`'s actor; null when `h` has gone or is driven by
    /// another behaviour.
    pub fn actor(t: *Tick, comptime M: type, h: Handle) ?Actor(M) {
        const e = t.world.get(h) orelse return null;
        const tag = comptime behaviours.tagOf(M);
        if (std.meta.activeTag(e.mind) != tag) return null;
        return .{ .tick = t, .handle = h, .entity = e, .kind = t.kindOf(e), .mind = &@field(e.mind, @tagName(tag)) };
    }

    // The hooks: what the systems ask of a behaviour; without the hook, its default.

    /// The player's command, for the entity a player plays (the control system).
    pub fn control(t: *Tick, h: Handle, command: Command) void {
        dispatch(t, h, "control", void, {}, .{command});
    }

    /// The entity's own decisions (the AI system).
    pub fn think(t: *Tick, h: Handle) void {
        dispatch(t, h, "think", void, {}, .{});
    }

    /// The entity's tick begins, at its turn, before the blows of the tick (systems.zig).
    pub fn begin(t: *Tick, h: Handle) void {
        dispatch(t, h, "begin", void, {}, .{});
    }

    /// A blow meets the entity's body: whether it takes it. Its behaviour's hook takes the
    /// damage itself; without the hook, it takes it at once.
    pub fn struck(t: *Tick, h: Handle, blow: Blow) bool {
        const e = t.world.get(h) orelse return false;
        if (hasHook(e, "struck")) return dispatch(t, h, "struck", bool, false, .{blow});
        t.takeDamage(h, blow.attacker, blow.damage);
        return true;
    }

    /// The entity's blow was taken by `target`.
    pub fn blowLanded(t: *Tick, h: Handle, target: Handle) void {
        dispatch(t, h, "blowLanded", void, {}, .{target});
    }

    /// Whether the weapon `h` stabs in its holder's hand whatever is ahead (a splintered bat).
    pub fn stabs(t: *Tick, h: Handle) bool {
        return dispatch(t, h, "stabs", bool, false, .{});
    }

    /// The blows the entity landed at this tick are forgotten (a breakable it broke cleared
    /// them).
    pub fn landingCleared(t: *Tick, h: Handle) void {
        dispatch(t, h, "landingCleared", void, {}, .{});
    }

    /// The entity moved by its speed, before its fall: its behaviour's `walls` (the players' walls
    /// of the round's floor by cells).
    pub fn walls(t: *Tick, h: Handle) void {
        dispatch(t, h, "walls", void, {}, .{});
    }

    /// The entity is in the air after its move. Its behaviour's `fall` decides whether it lands
    /// (`land`) and how it falls; by default it lands when it has come down to the floor under it,
    /// and otherwise its definition's gravity adds to its speed in height.
    pub fn fall(t: *Tick, h: Handle) void {
        const e = t.world.get(h) orelse return;
        if (hasHook(e, "fall")) return dispatch(t, h, "fall", void, {}, .{});
        if (t.onFloor(e.position) and e.velocity.height.raw >= 0) return t.land(h, .whole);
        e.velocity.height = e.velocity.height.add(.of(t.kindOf(e).definition.gravity));
    }

    /// The height of the floor under `at` (the round's floor by cells; else its ground
    /// everywhere), or null over a hole, where nothing stands.
    pub fn floorUnder(t: *const Tick, at: fixed.Vec3) ?Fixed {
        const p = t.plan orelse return t.world.ground;
        const f = p.round.floor orelse return t.world.ground;
        const cell = f.at(at.x.whole(), at.depth.whole());
        return if (cell.floor) .pixels(cell.height) else null;
    }

    /// The kind of the round's floor's cell under `at` (its whole pixels): none where the round
    /// has no floor by cells.
    pub fn cellAt(t: *const Tick, at: fixed.Vec3) ?content_round.FloorKind {
        const p = t.plan orelse return null;
        const f = p.round.floor orelse return null;
        return f.at(at.x.whole(), at.depth.whole());
    }

    /// The carry across a tick of the floor's cell under `at` (round 6's conveyors), in whole
    /// pixels: none where the floor is one kind of cell.
    pub fn carryUnder(t: *const Tick, at: fixed.Vec3) i8 {
        const p = t.plan orelse return 0;
        const f = p.round.floor orelse return 0;
        return f.at(at.x.whole(), at.depth.whole()).carry;
    }

    /// Whether `at` is down on the floor under it, or below it (over a hole: never).
    pub fn onFloor(t: *const Tick, at: fixed.Vec3) bool {
        const floor = t.floorUnder(at) orelse return false;
        return !at.height.lessThan(floor);
    }

    /// How a landing puts the entity on the ground: on its whole pixels, or with the fraction
    /// of its height kept and its speed in height left as it was (the original's objects other
    /// than the players set the whole pixels alone, and leave the speed).
    pub const Landing = enum { whole, fraction_kept };

    /// The entity lands on the ground: out of the air, its behaviour told (`landed`) while its
    /// speed of the fall is still there (a bounce takes some of it back); then, unless it is in
    /// the air again or its landing keeps it, that speed is gone.
    pub fn land(t: *Tick, h: Handle, how: Landing) void {
        const e = t.world.get(h) orelse return;
        // On the floor under it (the ground over a hole).
        const floor = t.floorUnder(e.position) orelse t.world.ground;
        e.position.height = switch (how) {
            .whole => floor,
            .fraction_kept => .parts(@intCast(floor.whole()), e.position.height.frac()),
        };
        e.flags.airborne = false;
        e.flags.landed = true;
        t.landed(h);
        if (how == .fraction_kept) return;
        if (t.world.get(h)) |x| if (!x.flags.airborne) {
            x.velocity.height = .zero;
        };
    }

    /// The entity was put in its state from a situation another program recorded (a converted
    /// start, DESIGN.md decision D14), `elapsed` logic ticks after it entered it: its behaviour
    /// takes it up from there.
    pub fn takeUp(t: *Tick, h: Handle, elapsed: u32) void {
        dispatch(t, h, "takeUp", void, {}, .{elapsed});
    }

    /// Taken up from a situation, the entity is held already, `elapsed` ticks since its hold
    /// began: the blow under way of its holder's move was taken.
    pub fn takeUpHeld(t: *Tick, h: Handle, elapsed: u32) void {
        dispatch(t, h, "takeUpHeld", void, {}, .{elapsed});
    }

    /// Taken up from a situation, the entity came to its state from the state named `from`.
    pub fn takeUpCameFrom(t: *Tick, h: Handle, from: []const u8) void {
        dispatch(t, h, "takeUpCameFrom", void, {}, .{from});
    }

    /// Taken up from a situation, the players' depths (whole pixels, by player; null: none) when
    /// the entity's state began.
    pub fn takeUpPlayersThen(t: *Tick, h: Handle, depths: [2]?i32) void {
        dispatch(t, h, "takeUpPlayersThen", void, {}, .{depths});
    }

    /// Taken up from a situation, the entity shows its frame (set already) `shown` ticks, its speed
    /// what it is since `ago` ticks, `draws` the last random draws by then: true when its
    /// behaviour took up the frame's ticks left itself.
    pub fn takeUpFrame(t: *Tick, h: Handle, shown: u32, ago: u32, draws: []const u16) bool {
        return dispatch(t, h, "takeUpFrame", bool, false, .{ shown, ago, draws });
    }

    /// Taken up from a situation, the entity's speed across has been what it is `across_ago`
    /// ticks, its animation `pose_ago` ticks.
    pub fn takeUpSince(t: *Tick, h: Handle, across_ago: u32, pose_ago: u32) void {
        dispatch(t, h, "takeUpSince", void, {}, .{ across_ago, pose_ago });
    }

    /// Taken up from a situation, a blow of `by` met the entity at the situation's tick, its
    /// `damage` felt at the next.
    pub fn takeUpMet(t: *Tick, h: Handle, by: Handle, damage: i16) void {
        dispatch(t, h, "takeUpMet", void, {}, .{ by, damage });
    }

    /// Taken up from a situation, the entity bounced `times` times in its state.
    pub fn takeUpBounces(t: *Tick, h: Handle, times: u8) void {
        dispatch(t, h, "takeUpBounces", void, {}, .{times});
    }

    /// Taken up from a situation, the entity's speed has been what it is for `ago` ticks; the
    /// last random draws by the tick it came (perhaps another's).
    pub fn takeUpCourse(t: *Tick, h: Handle, ago: u32, draws: []const u16) void {
        dispatch(t, h, "takeUpCourse", void, {}, .{ ago, draws });
    }

    /// Taken up from a situation, the entity's blow cost another health `ago` ticks before
    /// (null: at the situation's tick, felt at its next).
    pub fn takeUpLanded(t: *Tick, h: Handle, ago: ?u32) void {
        dispatch(t, h, "takeUpLanded", void, {}, .{ago});
    }

    /// Taken up from a situation, the player pressed B in its state of `elapsed` ticks, at its
    /// ticks `presses` (counted from the state's first, 0); the trace tells its blow's landing
    /// at its tick `landed_at`, if it landed.
    pub fn takeUpPresses(t: *Tick, h: Handle, elapsed: u32, presses: []const u32, landed_at: ?u32) void {
        dispatch(t, h, "takeUpPresses", void, {}, .{ elapsed, presses, landed_at });
    }

    /// Taken up from a situation, a blow cost the entity health `ago` ticks before, in its state;
    /// `striking`: its striker is still in the state it struck in.
    pub fn takeUpStruck(t: *Tick, h: Handle, ago: u32, striking: bool) void {
        dispatch(t, h, "takeUpStruck", void, {}, .{ ago, striking });
    }

    /// Taken up, the entity (a player) got up `ago` ticks before: it blinks for the rest of its
    /// blinking.
    pub fn takeUpBlink(t: *Tick, h: Handle, ago: u32) void {
        dispatch(t, h, "takeUpBlink", void, {}, .{ago});
    }

    /// Taken up, the entity (a player) has kneed the one it holds `knees` times in this hold.
    pub fn takeUpKnees(t: *Tick, h: Handle, knees: u8) void {
        dispatch(t, h, "takeUpKnees", void, {}, .{knees});
    }

    /// Taken up from a situation, the entity holds the weapon `weapon` (its holder set already).
    pub fn takeUpWeapon(t: *Tick, h: Handle, weapon: Handle) void {
        dispatch(t, h, "takeUpWeapon", void, {}, .{weapon});
    }

    /// Taken up from a situation, the weapon or item was picked up `times` times.
    pub fn takeUpTaken(t: *Tick, h: Handle, times: u8) void {
        dispatch(t, h, "takeUpTaken", void, {}, .{times});
    }

    /// Taken up from a situation, the shutter opened `ago` ticks before.
    pub fn takeUpOpened(t: *Tick, h: Handle, ago: u32) void {
        dispatch(t, h, "takeUpOpened", void, {}, .{ago});
    }

    /// The entity landed on the ground (the movement system).
    pub fn landed(t: *Tick, h: Handle) void {
        dispatch(t, h, "landed", void, {}, .{});
    }

    /// Whether `by` may grab the entity (by default, no).
    pub fn grabbable(t: *Tick, h: Handle, by: Handle) bool {
        return dispatch(t, h, "grabbable", bool, false, .{by});
    }

    /// Whether an enemy may set on the entity now: its behaviour's `attackable` says (a player
    /// struck down or blinking may not); by default, yes.
    /// Whether the round draws the things the fights leave and throw in front of its layers'
    /// cells in front of the sprites (`Round.in_front`).
    pub fn thingsInFront(t: *const Tick) bool {
        const p = t.plan orelse return false;
        return p.round.in_front.things;
    }

    pub fn attackable(t: *Tick, h: Handle) bool {
        return dispatch(t, h, "attackable", bool, true, .{});
    }

    /// Whether an enemy may catch the entity at this tick (`catchHeld`): its behaviour's
    /// `catchable` says (a player struck or caught at this tick may not); by default, yes.
    pub fn catchable(t: *Tick, h: Handle) bool {
        return dispatch(t, h, "catchable", bool, true, .{});
    }

    /// The grab began: the entity `holder` holds `held`.
    pub fn grabbed(t: *Tick, holder: Handle, held: Handle) void {
        dispatch(t, holder, "holds", void, {}, .{held});
        dispatch(t, held, "heldBy", void, {}, .{holder});
    }

    /// The hold of `holder` ends: neither holds the other any more, and the one it held is told
    /// (`letGoBy`), while its holder still shows the frame that let go.
    pub fn letGo(t: *Tick, holder: Handle) void {
        const e = t.world.get(holder) orelse return;
        const held = e.holding orelse return;
        e.holding = null;
        const o = t.world.get(held) orelse return;
        o.holder = null;
        dispatch(t, held, "letGoBy", void, {}, .{holder});
    }

    /// `holder` catches `held` (an enemy's hold of a player): from behind or the front. The one
    /// held is told (`caughtBy`), and holds nothing more.
    pub fn catchHeld(t: *Tick, holder: Handle, held: Handle, behind: bool) void {
        const h = t.world.get(holder) orelse return;
        const o = t.world.get(held) orelse return;
        if (o.holding != null) t.letGo(held);
        h.holding = held;
        o.holder = holder;
        dispatch(t, held, "caughtBy", void, {}, .{ holder, behind });
    }

    /// The kind of the rolling shutter an enemy lies in wait behind.
    pub const shutter_kind = "shutter";

    /// The enemy `by` puts up its shutter at its place, a pixel deeper, in the first of the
    /// enemies' free places (the last of them when none is free): the shutter lets it out
    /// (`letOut`).
    pub fn putUpShutter(t: *Tick, by: Handle) void {
        const kind = t.kinds.find(shutter_kind) orelse return;
        const e = t.world.get(by) orelse return;
        const p = world_mod.World.enemy_places;
        const at: fixed.Vec3 = .{ .x = .pixels(e.position.x.whole()), .depth = .pixels(e.position.depth.whole() + 1), .height = .pixels(e.position.height.whole()) };
        const s = t.world.spawnWithin(t.kinds, kind, p.from, p.to, at, .right) catch t.world.spawnWithin(t.kinds, kind, p.to, p.to + 1, at, .right) catch return;
        t.world.get(s).?.mind.shutter.owner = by;
    }

    /// The shutter the enemy `h` lay in wait behind lets it out.
    pub fn letOut(t: *Tick, h: Handle) void {
        dispatch(t, h, "letOut", void, {}, .{});
    }

    /// `by` takes up a new weapon of the kind named `name`, in one of the weapons' places
    /// (`World.weapon_places`), unseen until it is in the hand: the pick-up is noted. Null when
    /// no place is free.
    pub fn arm(t: *Tick, by: Handle, name: []const u8) ?Handle {
        const kind = t.kinds.find(name) orelse return null;
        const p = world_mod.World.weapon_places;
        const w = t.world.spawnWithin(t.kinds, kind, p.from, p.to, .zero, .right) catch return null;
        const e = t.world.get(w).?;
        e.holder = by;
        e.flags.hidden = true;
        t.out.pickups.append(.{ .item = w, .kind = kind, .by = by });
        return w;
    }

    /// The holder of the weapon `w` throws it (`hurled`): it flies from its turn.
    pub fn throwWeapon(t: *Tick, w: Handle) void {
        dispatch(t, w, "hurled", void, {}, .{});
    }

    /// The weapon `w` falls from its holder's hand (`dropped`).
    pub fn dropWeapon(t: *Tick, w: Handle) void {
        dispatch(t, w, "dropped", void, {}, .{});
    }

    /// The holder of the weapon `w` took another: `w` lies where it is (`putDown`).
    pub fn putDownWeapon(t: *Tick, w: Handle) void {
        dispatch(t, w, "putDown", void, {}, .{});
    }

    /// A player's entity moved in its turn (the players' move): its behaviour's `moved` (a hold
    /// between the players places it).
    pub fn moved(t: *Tick, h: Handle) void {
        dispatch(t, h, "moved", void, {}, .{});
    }

    /// Whether the camera keeps the player's entity in its view: its behaviour's `keptInView`;
    /// by default, unless it holds or is held.
    pub fn keptInView(t: *Tick, h: Handle) bool {
        const e = t.world.get(h) orelse return false;
        if (hasHook(e, "keptInView")) return dispatch(t, h, "keptInView", bool, true, .{});
        return e.holding == null and e.holder == null;
    }

    /// How the player's entity may meet the other player's at this tick
    /// (`systems.betweenPlayers`): its behaviour's `touchClass`; by default, not at all (0).
    pub fn touchClass(t: *Tick, h: Handle) u8 {
        return dispatch(t, h, "touchClass", u8, 0, .{});
    }

    /// The entity is held: it follows its holder now that its holder has moved (`follow`; by
    /// default its holder places it).
    pub fn follow(t: *Tick, h: Handle) void {
        dispatch(t, h, "follow", void, {}, .{});
    }

    /// `holder` throws the one it holds, a throw of `damage` (`thrownBy`: the one thrown lets go
    /// when its throw ends).
    /// The enemy `holder`, holding `held`, asks it what its hold does (the original's reaction
    /// it writes into the one held, `ask`): held from the front (2), from behind (3), slammed down
    /// (4), tossed over (9); a throw's landing costs it `damage`. The one held answers at its next
    /// tick (`askedBy`).
    pub fn askHeld(t: *Tick, held: Handle, holder: Handle, ask: u8, damage: i16) void {
        dispatch(t, held, "askedBy", void, {}, .{ holder, ask, damage });
    }

    /// The one held is shaken down by its holder (the original's mark on it), turned to `facing`
    /// when given: shaken (`askHeld`'s 11) it falls at its next tick (`shook`).
    pub fn shakeHeld(t: *Tick, held: Handle, facing: ?entity.Facing) void {
        dispatch(t, held, "shook", void, {}, .{facing});
    }

    /// Whether the one `holder` holds may get out of its hold by itself (by default, yes).
    pub fn holdEscapable(t: *Tick, holder: Handle) bool {
        return dispatch(t, holder, "holdEscapable", bool, true, .{});
    }

    pub fn throwHeld(t: *Tick, holder: Handle, damage: i16) void {
        const h = t.world.get(holder) orelse return;
        const held = h.holding orelse return;
        dispatch(t, held, "thrownBy", void, {}, .{ holder, damage });
    }

    /// The one `by` turns the hold it is in: it now holds its holder, who is told (`heldBy`).
    /// Returns whether it did.
    pub fn turnHold(t: *Tick, by: Handle) bool {
        const e = t.world.get(by) orelse return false;
        const holder = e.holder orelse return false;
        const h = t.world.get(holder) orelse return false;
        h.holding = null;
        e.holder = null;
        e.holding = holder;
        h.holder = by;
        dispatch(t, holder, "heldBy", void, {}, .{by});
        return true;
    }

    /// A heavy fall shakes the screen, unless a shake is under way or the special attack is.
    pub fn shake(t: *Tick) void {
        const c = &t.world.camera;
        if (t.world.special or c.shake != 0) return;
        const rules = c.follows orelse return;
        c.shake = rules.shake_ticks;
    }

    /// The player whose entity is `h` scores `points` (nothing when `h` is no player's).
    pub fn score(t: *Tick, h: Handle, points: u32) void {
        for (&t.world.players) |*p| {
            const e = p.entity orelse continue;
            if (!e.eql(h)) continue;
            p.score = @min(p.score +| points, t.world.score_most);
            return;
        }
    }

    /// The players in play: those who have an entity in the world.
    pub fn playersInPlay(t: *const Tick) u8 {
        var n: u8 = 0;
        for (t.world.players) |p| {
            if (p.entity) |h| if (t.world.getConst(h) != null) {
                n += 1;
            };
        }
        return n;
    }

    /// Player `k`'s entity while the enemies can go after it: while it is in play
    /// (`lives.inPlay`: as a fighter, or out of lives at the tick its last life ended and at the
    /// tick its name is entered).
    pub fn fighting(t: *const Tick, k: usize) ?Handle {
        if (!lives.inPlay(t.world, @intCast(k))) return null;
        return t.world.players[k].entity;
    }

    /// Whether every player in play plays as a fighter (none waits to continue): the round's
    /// timer runs only then.
    pub fn playersPlay(t: *const Tick) bool {
        for (t.world.players) |p| {
            const e = t.world.getConst(p.entity orelse continue) orelse continue;
            if (e.mind != .player) return false;
        }
        return true;
    }

    /// An enemy left behind the camera was brought back to its edge by the round's script: its
    /// behaviour takes it up from there (`leftBehind`).
    pub fn leftBehind(t: *Tick, h: Handle) void {
        dispatch(t, h, "leftBehind", void, {}, .{});
    }

    /// A player's new life drops in: the enemies on the screen (out of hiding, neither held by a
    /// player nor holding one: the original spares the one a player's hold names) are knocked
    /// back (their behaviour's `knockedBack`).
    pub fn knockBack(t: *Tick) void {
        for (&t.world.entities, 0..) |*e, i| {
            if (!e.alive() or e.flags.hidden or e.holder != null) continue;
            if (e.holding) |h| if (t.isPlayer(h)) continue;
            switch (t.kindOf(e).family()) {
                .enemy, .boss => {},
                else => continue,
            }
            dispatch(t, t.world.handleAt(i).?, "knockedBack", void, {}, .{});
        }
    }

    /// The boss of the boss's section beaten (the last of twins): the players held are freed,
    /// and every enemy shown, but those knocked out, is knocked down, its health gone (the
    /// original's end of the fight; the traces see a blow by no one).
    pub fn bossBeaten(t: *Tick) void {
        for (t.world.players) |p| {
            const ph = p.entity orelse continue;
            const pe = t.world.get(ph) orelse continue;
            if (pe.holder) |h| if (!t.isPlayer(h)) t.letGo(h);
        }
        for (World.enemy_places.from..World.enemy_places.to) |i| {
            const e = &t.world.entities[i];
            if (!e.alive() or e.flags.hidden) continue;
            if (t.kindOf(e).family() != .enemy) continue;
            const name = behaviours.stateName(&e.mind) orelse "";
            if (std.mem.eql(u8, name, "knocked_out")) continue;
            const h = t.world.handleAt(i).?;
            const lost = e.health + 1;
            if (!t.specialKnockDown(h, null, .beaten)) continue;
            e.health = -1;
            t.out.hits.append(.{ .attacker = null, .target = h, .damage = lost });
        }
    }

    /// A beaten boss ends the round: the round is won (script.zig).
    pub fn roundWon(t: *Tick) void {
        script.won(t.world);
    }

    /// Whether a thing at `x` across is left behind by the camera: at or left of the camera's place
    /// less `by`, as the original compares their whole pixels' words, unsigned (with the camera
    /// within `by` of the level's start, any place is).
    pub fn behindCamera(t: *const Tick, x: Fixed, by: i16) bool {
        const edge: u16 = @truncate(@as(u32, @bitCast(t.world.camera.x.whole() - by)));
        const at: u16 = @truncate(@as(u32, @bitCast(x.whole())));
        return edge >= at;
    }

    /// Whether `h` is a player's entity.
    pub fn isPlayer(t: *const Tick, h: Handle) bool {
        for (t.world.players) |p| if (p.entity) |e| if (e.eql(h)) return true;
        return false;
    }

    /// The kind of entity of a special attack's call: the special attack's own (it brings the
    /// police car and the shot, and knocks the enemies down).
    pub const special_kind = "special_knockdown";

    /// A player calls the special attack: unless one is under way, its own comes, at the world's
    /// origin, never drawn (its behaviour runs the attack), and every entity on the screen is
    /// told (`specialCalled`). Returns whether it came.
    pub fn callSpecial(t: *Tick, by: Handle) bool {
        if (t.world.special) return false;
        const kind = t.kinds.find(special_kind) orelse return false;
        t.world.special_by = by;
        const places = behaviours.special_knockdown.places;
        const own = t.world.spawnWithin(t.kinds, kind, places.from, places.to, .zero, .right) catch return false;
        if (t.world.get(own)) |e| e.flags.on_screen = false;
        t.world.special = true;
        dispatch(t, own, "specialCalled", void, {}, .{});
        var buf: [capacity_]u8 = undefined;
        for (t.world.updateOrder(&buf)) |i| {
            const h = t.world.handleAt(i) orelse continue;
            const e = t.world.get(h).?;
            if (e.flags.hidden or h.eql(own) or h.eql(by)) continue;
            dispatch(t, h, "specialCalled", void, {}, .{});
        }
        return true;
    }

    /// How the special attack knocks an enemy down: below its line in depth (player 1's, but
    /// one in its knock-down's pose), the rest (but one in that pose short of its frame `rest`),
    /// any (player 2's); beaten (the boss of the section beaten: at once, its set-up at its own
    /// turn when that is still to come).
    pub const SpecialFall = union(enum) { line: i16, rest: u8, any, beaten };

    /// The special attack knocks `h` down, as `how` says, its blow `by`'s (its caller's): whether
    /// it fell (its behaviour's `specialKnockedDown`; by default, not).
    pub fn specialKnockDown(t: *Tick, h: Handle, by: ?Handle, how: SpecialFall) bool {
        return dispatch(t, h, "specialKnockedDown", bool, false, .{ by, how });
    }

    /// The first solid thing (in the world's order) other than `h` whose `solid` box holds
    /// `place` (whole pixels, across and in depth).
    fn solidThere(t: *const Tick, h: Handle, place: Vec3) ?*const Entity {
        const x = place.x.whole();
        const d = place.depth.whole();
        for (&t.world.entities, 0..) |*o, i| {
            if (!o.alive() or !o.flags.solid or i == h.index) continue;
            const def = t.kindOf(o).definition;
            const b = def.boxes[def.box("solid") orelse continue];
            const ox = o.position.x.whole();
            const od = o.position.depth.whole();
            if (x < ox + b.x.from or x > ox + b.x.to) continue;
            if (d < od + b.depth.from or d > od + b.depth.to) continue;
            return o;
        }
        return null;
    }

    /// `h` moved into a solid thing (a breakable): its move is undone by its speed, across and
    /// in depth; moving across only, it stands against the thing's side (its whole pixels; its
    /// fraction kept); its speed across and in depth goes. Whether it was (as in the original's
    /// fighters' walks).
    pub fn keptOut(t: *Tick, h: Handle) bool {
        const e = t.world.get(h) orelse return false;
        const o = t.solidThere(h, e.position) orelse return false;
        e.position.x = e.position.x.sub(e.velocity.x);
        e.position.depth = e.position.depth.sub(e.velocity.depth);
        if (e.velocity.depth.raw == 0) {
            const def = t.kindOf(o).definition;
            const b = def.boxes[def.box("solid").?];
            const ox = o.position.x.whole();
            const side = if (ox >= e.position.x.whole()) ox + b.x.from - 1 else ox + b.x.to + 1;
            e.position.x = .parts(@intCast(side), e.position.x.frac());
        }
        e.velocity.x = .zero;
        e.velocity.depth = .zero;
        return true;
    }

    /// The round's script gives the entity `item` to hold (a breakable's, which it leaves).
    pub fn give(t: *Tick, h: Handle, item: entity.KindId) void {
        dispatch(t, h, "given", void, {}, .{item});
    }

    /// The first item or weapon (in the world's order) that nothing holds whose place lies
    /// within `across` and `depth` pixels of `e`'s, and from its feet up to `height` above.
    pub fn itemNear(t: *Tick, e: *const Entity, across: i16, depth: i16, height: i16) ?Handle {
        var buf: [capacity_]u8 = undefined;
        for (t.world.updateOrder(&buf)) |i| {
            const oh = t.world.handleAt(i) orelse continue;
            const o = t.world.get(oh).?;
            if (o == e) continue;
            const family = t.kindOf(o).family();
            if (family != .item and family != .weapon) continue;
            if (o.holder != null) continue;
            if (family == .weapon and !dispatch(t, oh, "takeable", bool, true, .{})) continue;
            const dx = o.position.x.whole() - e.position.x.whole();
            const dd = o.position.depth.whole() - e.position.depth.whole();
            const dh = o.position.height.whole() - e.position.height.whole();
            if (@abs(dx) > across or @abs(dd) > depth or dh < -height or dh > 0) continue;
            return oh;
        }
        return null;
    }

    /// The item or weapon `item` is picked up by `by`: whether it stays in the world (by
    /// default it goes), and what `by` does with it.
    pub fn pickedUp(t: *Tick, item: Handle, by: Handle) void {
        dispatch(t, by, "picks", void, {}, .{item});
        if (!dispatch(t, item, "pickedUp", bool, false, .{by})) t.world.remove(item);
    }
};

/// Whether `e`'s behaviour has the hook `hook`.
fn hasHook(e: *const Entity, comptime hook: []const u8) bool {
    switch (e.mind) {
        .none => return false,
        inline else => |_, tag| return @hasDecl(behaviours.module(tag), hook),
    }
}

/// Calls hook `hook` of `h`'s behaviour with the actor and `args`; `default` when the entity has
/// gone or its behaviour has no such hook.
fn dispatch(t: *Tick, h: Handle, comptime hook: []const u8, comptime R: type, default: R, args: anytype) R {
    const e = t.world.get(h) orelse return default;
    switch (e.mind) {
        .none => return default,
        inline else => |*m, tag| {
            const M = behaviours.module(tag);
            if (!@hasDecl(M, hook)) return default;
            const a: Actor(M) = .{ .tick = t, .handle = h, .entity = e, .kind = t.kindOf(e), .mind = m };
            return @call(.auto, @field(M, hook), .{a} ++ args);
        },
    }
}

/// An entity seen by its behaviour `M`. A hook that removes its entity returns at once: its
/// fields are then free.
pub fn Actor(comptime M: type) type {
    return struct {
        const Self = @This();

        tick: *Tick,
        handle: Handle,
        entity: *Entity,
        kind: *const Kind,
        mind: *M.Mind,

        /// The behaviour's numbers, as `M.Numbers` types them, from the definition.
        pub fn numbers(a: Self) M.Numbers {
            return kinds_mod.numbersOf(M, a.kind);
        }

        /// The behaviour's tables (`M.Tables`), from the definition.
        pub fn tables(a: Self) *const M.Tables {
            return @ptrCast(@alignCast(a.kind.tables.?));
        }

        /// The behaviour's choices of states (`M.Choices`), from the definition.
        pub fn choices(a: Self) *const M.Choices {
            return @ptrCast(@alignCast(a.kind.choices.?));
        }

        /// Starts the animation `which` from its first frame (that frame's sound asked for).
        pub fn animate(a: Self, which: M.Animation) void {
            a.tick.startAnimation(a.handle, a.entity, a.kind.animation_of[@backingInt(which)]);
        }

        // The animation driven by the behaviour (`drives_animation`, behaviours.zig).

        /// The frame of its animation it is on.
        pub fn frame(a: Self) u8 {
            return a.entity.animation.frame;
        }

        /// Whether the animation `which` is the one it plays.
        pub fn plays(a: Self, which: M.Animation) bool {
            return a.playing(which);
        }

        /// Holds its frame (`paused`), or lets the animation run again.
        pub fn pause(a: Self, paused: bool) void {
            a.entity.animation.paused = paused;
        }

        /// Each frame shows `ticks` ticks (null: its own), and the frame it is on `left` more.
        pub fn pace(a: Self, ticks: ?u8, left: u8) void {
            a.entity.animation.pace = ticks;
            a.entity.animation.left = left;
        }

        /// The frame `index` of the animation it plays, from now (the animation system shows it
        /// and puts its boxes in use at the tick's end).
        pub fn setFrame(a: Self, index: u8) void {
            a.entity.animation.frame = a.frameWithin(index);
        }

        /// `index` as a frame of the animation it plays: past its last (a rule gone wrong), its
        /// last, and the fault told (`frameOutside`).
        fn frameWithin(a: Self, index: u8) u8 {
            const an = a.currentAnimation() orelse return index;
            if (index < an.frames.len) return index;
            frameOutside(a.kind.definition.name, an.name, behaviours.stateName(&a.entity.mind) orelse "", index, an.frames.len);
            return @intCast(an.frames.len - 1);
        }

        /// One tick of its animation: the frame's ticks count down; when they run out the
        /// next frame comes (after the last, the first), with its boxes and its sound. Returns
        /// whether the frame changed.
        pub fn step(a: Self) bool {
            if (!a.countDown()) return false;
            const an = a.currentAnimation() orelse return false;
            const next = if (a.entity.animation.frame + 1 < an.frames.len) a.entity.animation.frame + 1 else 0;
            a.showFrame(next, null);
            return true;
        }

        /// The frame's ticks count down, the frame staying (a state timed by its frame):
        /// whether they ran out.
        pub fn countDown(a: Self) bool {
            a.entity.animation.left -%= 1;
            return a.entity.animation.left == 0;
        }

        /// The ticks the frame still shows.
        pub fn ticksLeft(a: Self) u8 {
            return a.entity.animation.left;
        }

        pub fn setTicksLeft(a: Self, ticks: u8) void {
            a.entity.animation.left = ticks;
        }

        /// The frame `index` of the animation playing shows from now, for `ticks` ticks (its
        /// own by default), with its boxes; its sound is asked for.
        pub fn showFrame(a: Self, index: u8, ticks: ?u8) void {
            const an = a.currentAnimation() orelse return;
            const i = a.frameWithin(index);
            a.entity.animation.frame = i;
            a.entity.animation.left = ticks orelse an.frames[i].ticks;
            a.showBoxes();
            a.tick.frameStarts(a.handle, a.entity);
        }

        /// The animation `which` plays on from the frame it is on, with `ticks` left: another
        /// timing of the same frames.
        pub fn retime(a: Self, which: M.Animation, ticks: u8) void {
            a.entity.animation.index = a.kind.animation_of[@backingInt(which)];
            a.entity.animation.frame = a.frameWithin(a.entity.animation.frame);
            a.entity.animation.left = ticks;
        }

        /// The boxes of the frame it shows, facing as it faces.
        pub fn showBoxes(a: Self) void {
            const an = a.currentAnimation() orelse return;
            const f = an.frames[a.entity.animation.frame];
            a.entity.boxes = .{ .body = f.body, .attack = f.attack, .mirrored = a.entity.facingLeft() != f.flip };
        }

        fn currentAnimation(a: Self) ?*const content_entity.Animation {
            const index = a.entity.animation.index orelse return null;
            return &a.kind.definition.animations[index];
        }

        /// Whether it shows the last frame of its animation (or none).
        pub fn atLastFrame(a: Self) bool {
            const an = a.currentAnimation() orelse return true;
            return a.entity.animation.frame + 1 >= an.frames.len;
        }

        /// The frame it shows, as its definition gives it.
        pub fn currentFrame(a: Self) ?*const content_entity.Frame {
            return a.tick.frameOf(a.entity);
        }

        /// The damage its blow does at this tick (`Tick.power`).
        pub fn power(a: Self) i16 {
            return a.tick.power(a.entity);
        }

        /// Whether its place is down on the floor under it, or below it (over a hole: never).
        pub fn atGround(a: Self) bool {
            return a.tick.onFloor(a.entity.position);
        }

        /// It lands (`Tick.land`).
        pub fn land(a: Self, how: Tick.Landing) void {
            a.tick.land(a.handle, how);
        }

        /// It takes `damage` from `attacker` (`Tick.takeDamage`).
        pub fn takeDamage(a: Self, attacker: ?Handle, damage: i16) void {
            a.tick.takeDamage(a.handle, attacker, damage);
        }

        /// The hold it is in ends, whether it holds or is held (`Tick.letGo`).
        pub fn letGo(a: Self) void {
            if (a.entity.holding != null) return a.tick.letGo(a.handle);
            if (a.entity.holder) |h| a.tick.letGo(h);
        }

        /// An item near it (`Tick.itemNear`).
        pub fn itemNear(a: Self, across: i16, depth: i16, height: i16) ?Handle {
            return a.tick.itemNear(a.entity, across, depth, height);
        }

        /// It picks up `item`: noted for the traces, and the item's behaviour told.
        pub fn pickUp(a: Self, item: Handle) void {
            const o = a.tick.world.get(item) orelse return;
            a.tick.out.pickups.append(.{ .item = item, .kind = o.kind.?, .by = a.handle });
            a.tick.pickedUp(item, a.handle);
        }

        /// Whether the animation `which` plays.
        pub fn playing(a: Self, which: M.Animation) bool {
            return a.entity.animation.index == a.kind.animation_of[@backingInt(which)];
        }

        /// Plays the animation `which`, starting it unless it plays already.
        pub fn keepAnimating(a: Self, which: M.Animation) void {
            if (!a.playing(which)) a.animate(which);
        }

        /// Whether the animation has shown all its frames.
        pub fn animationDone(a: Self) bool {
            return a.entity.animation.done;
        }

        /// Starts the move `which`: its animation, its sound.
        pub fn startMove(a: Self, which: M.Move) void {
            a.tick.startMove(a.handle, a.entity, a.kind.move_of[@backingInt(which)]);
        }

        pub fn endMove(a: Self) void {
            a.entity.move = null;
        }

        /// Its blow `blow` with its box `which`, outside its moves: it strikes the players as a
        /// blow under way at its turn does (systems.zig).
        pub fn strikePlayers(a: Self, which: M.Box, blow: Blow) void {
            systems.strikePlayers(a.tick, a.handle, a.kind.box_of[@backingInt(which)], blow);
        }

        /// Asks for the sound `which` of its definition.
        pub fn sound(a: Self, which: M.Sound) void {
            a.tick.sound(a.kind.sound_of[@backingInt(which)], a.handle);
        }

        /// Its colours `which` in the colours shown (from the next frame).
        pub fn showColours(a: Self, which: M.Colours) void {
            a.tick.out.colour_loads.append(.{ .palette = a.kind.colours_of[@backingInt(which)] });
        }

        pub fn draw(a: Self, comptime purpose: random.Purpose) u16 {
            return a.tick.draw(purpose);
        }

        pub fn pick(a: Self, comptime purpose: random.Purpose, comptime n: u16) u16 {
            return a.tick.pick(purpose, n);
        }

        pub fn stop(a: Self) void {
            a.entity.velocity = .zero;
        }

        /// Takes off with `height_speed` (negative: up).
        pub fn leap(a: Self, height_speed: Fixed) void {
            a.entity.velocity.height = height_speed;
            a.entity.flags.airborne = true;
        }

        /// The speed of the blow: across away from its striker, and up, in the air.
        pub fn takePush(a: Self, blow: Blow) void {
            a.entity.velocity = .{ .x = blow.push.x, .height = blow.push.height };
            if (blow.push.height.raw != 0) a.entity.flags.airborne = true;
        }

        /// Faces `target`'s side.
        pub fn faceToward(a: Self, target: *const Entity) void {
            const dx = target.position.x.sub(a.entity.position.x);
            if (dx.raw != 0) a.entity.facing = if (dx.raw < 0) .left else .right;
        }

        /// The nearest entity of `team` other than itself (by the distance across plus the
        /// distance in depth; the first in the pool among equals).
        pub fn nearest(a: Self, team: entity.Team) ?Handle {
            var best: ?Handle = null;
            var best_d: i64 = std.math.maxInt(i64);
            for (&a.tick.world.entities, 0..) |*o, i| {
                if (!o.alive() or o.team != team or i == a.handle.index) continue;
                const d = @as(i64, @abs(o.position.x.sub(a.entity.position.x).raw)) + @abs(o.position.depth.sub(a.entity.position.depth).raw);
                if (d < best_d) {
                    best_d = d;
                    best = a.tick.world.handleAt(i);
                }
            }
            return best;
        }

        pub fn other(a: Self, h: Handle) ?*Entity {
            return a.tick.world.get(h);
        }

        /// The entity goes; the hook returns at once.
        pub fn remove(a: Self) void {
            a.tick.world.remove(a.handle);
        }
    };
}
