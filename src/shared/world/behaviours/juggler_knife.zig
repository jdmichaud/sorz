//! The juggler's knives (juggler.zig). A juggling begins with a maker (`maker`, unseen): it
//! makes the knives `maker_gap` ticks apart in the enemies' free places, then goes. A knife
//! (`start`) is juggled (`juggled`): thrown up from beside its juggler's hand, its place across
//! its juggler's plus an offset that drifts, it comes down in an arc; back at its height, while
//! its juggler walks it goes back to the hand (else it falls away, `caught`). Back at the hand
//! it is juggled again, unless its juggler raises its knives: then the first back is tossed high
//! (`tossed`: it rises, hangs a while above, and falls back to be caught or to fall away), and
//! the next is caught: put in the hand (`flying`), it waits for its juggler's throw's frame and
//! flies off straight. Its blow knocks a player down; a blow on it in its arc makes a copy fall
//! away behind its juggler, and a blow on it in flight turns it back, falling; a weapon swung by
//! a player sends it toward the screen's edge, and again at the other player. Out of the screen
//! or into the ground, it goes; with no player left, it falls away. Its numbers, its animations
//! and boxes are its definition's (`entities/juggler_knife.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const world_mod = @import("../world.zig");
const juggler = @import("juggler.zig");
const systems = @import("../systems.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Entity = entity.Entity;
const Actor = tick.Actor(@This());

pub const State = enum { start, juggled, tossed, caught, flying, maker };

pub const Mind = struct {
    state: State = .start,
    /// Its state's set-up is due (its first tick).
    fresh: bool = true,
    /// Its juggler.
    holder: ?Handle = null,
    /// Made to be thrown at once (not juggled first).
    thrown: bool = false,
    /// The maker's knives left to make and its wait; a tossed knife's ticks hanging.
    count: u8 = 0,
    wait: u8 = 0,
    /// Juggled: its place across from its juggler's.
    offset: Fixed = .zero,
    /// Juggled, going back to the hand; tossed, past its top; in flight, launched.
    back: bool = false,
    /// A touch under way (a blow on it or its blow) since a tick without one; a touch at this
    /// tick.
    contact: bool = false,
    touched: bool = false,
    /// Its tick ends at this tick's touch.
    ends: bool = false,
    /// Sent off by a swung weapon once.
    deflected: bool = false,
    /// Its blow's damage.
    power: u8 = 0,
    /// Its place across on the screen as its last tick drew it (where the original's flight looks
    /// for the screen's sides).
    drawn: i16 = 0,
};

pub const Animation = enum { knife, knife_b };

pub const Numbers = struct {
    power: u8,
    maker_knives: u8,
    maker_first: u8,
    maker_gap: u8,
    pace: u8,
    /// The round it is drawn in front of its layers' cells in.
    front_round: u8,
    /// Juggled: its height and speeds as it leaves the hand, its offset across from its juggler
    /// (facing left, the other), below its juggler's depth; its speed back to the hand.
    juggle_height: i16,
    juggle_up: Fixed,
    juggle_across: Fixed,
    juggle_offset: i16,
    juggle_offset_left: i16,
    juggle_depth: i16,
    juggle_back: Fixed,
    /// The hand across from its juggler (facing left, `hand_left`); a knife caught there, and a
    /// tossed one at its top (its opposite facing left).
    hand: i16,
    hand_left: i16,
    caught_x: i16,
    /// A knife struck in its arc: a copy falls away, up and behind its juggler at these.
    copy_up: Fixed,
    copy_across: i16,
    /// Tossed: its speed up, its top, its place across there, its ticks hanging, the height
    /// below its juggler's where it is caught.
    toss_up: Fixed,
    toss_top: i16,
    toss_x: i16,
    toss_hang: u8,
    toss_catch: i16,
    /// In the hand: its place from its juggler's; its juggler's frame that throws it, how much
    /// lower and how far ahead it leaves, its speed.
    hand_depth: i16,
    hand_height: i16,
    hand_x: i16,
    launch_frame: u8,
    launch_drop: i16,
    launch_speed: Fixed,
    launch_ahead: i16,
    /// A blow turns it back, up at this.
    turn_up: Fixed,
    /// A swung weapon sends it toward the screen's edge (its left, or `deflect_width` on), at
    /// a drawn depth; again, at the other player, with more power.
    deflect_speed: Fixed,
    deflect_width: i16,
    redirect_power: u8,
    redirect_speed: Fixed,
    /// Across from the camera's place, the sides it flies within (the latter excluded).
    flight_from: i16,
    flight_to: i16,
    fall_most: Fixed,
    /// A player's reach meets it within this height of the player's.
    grab_height: i16,
    /// A player's blow lands on it only drawn within these across at its last tick, the
    /// latter excluded (the screen's middle).
    struck_from: i16,
    struck_to: i16,
};

pub const Tables = struct {
    deflect_depth: [4]i16,
};

pub fn begin(a: Actor) void {
    const m = a.mind;
    m.touched = false;
    m.ends = false;
    switch (m.state) {
        .maker => if (m.fresh) {
            m.fresh = false;
            a.entity.flags.hidden = true;
            a.entity.flags.stays = true;
            m.count = a.numbers().maker_knives;
            m.wait = a.numbers().maker_first;
        },
        .start => start(a),
        .juggled => if (m.fresh) juggledSetUp(a),
        .tossed => if (m.fresh) tossedSetUp(a),
        .flying => {
            if (m.fresh) flyingSetUp(a);
            if (!m.back) inHand(a);
        },
        .caught => {
            // A copy unseen until its first turn (`copy`) shows from it.
            if (m.fresh) a.entity.flags.hidden = false;
            m.fresh = false;
        },
    }
}

pub fn think(a: Actor) void {
    const m = a.mind;
    a.entity.flags.still = true;
    defer m.drawn = @intCast(a.entity.position.x.whole() - a.tick.world.camera.x.whole());
    switch (m.state) {
        .maker => return maker(a),
        .start => {},
        .juggled => if (!m.ends and !juggled(a)) return,
        .tossed => if (!tossed(a)) return,
        // Turned back by a blow at this tick, it falls away from its next.
        .caught => if (!m.ends and !falls(a)) return a.remove(),
        .flying => if (!m.ends and !flying(a)) return,
    }
    if (!m.touched) m.contact = false;
}

/// Enters `state`, its set-up at its next tick.
fn enter(a: Actor, state: State) void {
    a.mind.state = state;
    a.mind.fresh = true;
    a.mind.back = false;
    // A new state starts with no touch under way and not sent off yet (the original's state
    // word clears them): a blow on a knife juggled again makes a new copy.
    a.mind.contact = false;
    a.mind.deflected = false;
    // Falling away, it strikes no more from then on.
    if (state == .caught) a.entity.missile = null;
}

fn holder(a: Actor) ?*Entity {
    const h = a.mind.holder orelse return null;
    const e = a.other(h) orelse return null;
    return if (e.mind == .juggler) e else null;
}

/// Its juggler's place at this tick: where its speed takes it when its turn came before the
/// knife's (the original's things move in their own turns; the world moves them after all of
/// them), else where it is.
fn movedPlace(a: Actor, h: *const Entity) fixed.Vec3 {
    if (a.mind.holder.?.index > a.handle.index) return h.position;
    return systems.movedPlace(h);
}

fn juggling(e: *Entity) *juggler.Memory {
    return &e.mind.juggler.juggler;
}

// The maker, the start -----------------------------------------------------------------------

/// It makes its knives, a wait apart, in the enemies' free places (none: it tries again when its
/// wait comes round), then goes.
fn maker(a: Actor) void {
    const m = a.mind;
    m.wait -%= 1;
    if (m.wait != 0) return;
    const places = world_mod.World.enemy_places;
    const h = a.tick.world.spawnWithin(a.tick.kinds, a.entity.kind.?, places.from, places.to, .zero, .right) catch return;
    const k = a.tick.world.get(h).?;
    k.flags.still = true;
    k.flags.stays = true;
    k.mind.juggler_knife.holder = m.holder;
    m.count -%= 1;
    if (m.count == 0) return a.remove();
    m.wait = a.numbers().maker_gap;
}

/// Its look by its juggler's knives (its spawn's trait), paced; never left behind; then thrown
/// at once, or juggled from this tick.
fn start(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    m.power = n.power;
    const b = if (holder(a)) |h| h.spawn.traits.knives_b else false;
    a.animate(if (b) .knife_b else .knife);
    a.pace(n.pace, n.pace);
    a.entity.flags.stays = true;
    if (a.tick.plan) |p| a.entity.flags.in_front = p.round.number == n.front_round;
    if (m.thrown) return enter(a, .flying);
    enter(a, .juggled);
    juggledSetUp(a);
}

// Juggled -------------------------------------------------------------------------------------

/// It leaves the hand: at its height, up and drifting back, its offset beside its juggler's
/// hand; its frames run.
fn juggledSetUp(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    m.fresh = false;
    a.pause(false);
    e.position.height = .parts(n.juggle_height, e.position.height.frac());
    e.velocity.height = n.juggle_up;
    e.velocity.x = n.juggle_across;
    const left = if (holder(a)) |h| h.facingLeft() else false;
    m.offset = .parts(if (left) n.juggle_offset_left else n.juggle_offset, m.offset.frac());
    e.missile = missile(a);
}

/// Its blow on the players: its power, by its juggler.
fn missile(a: Actor) ?entity.Missile {
    const by = a.mind.holder orelse return null;
    return .{ .by = by, .damage = a.mind.power, .on_players = true };
}

/// A tick of its arc: by its juggler (gone, or no player left: it falls away), its offset
/// drifting; down at its height, back to the hand while its juggler walks; at the hand, as its
/// juggler raises its knives or not. False when its state changed.
fn juggled(a: Actor) bool {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    // No player in play (the last one's life over, its wait begun): it falls away.
    if (a.tick.fighting(0) == null and a.tick.fighting(1) == null) {
        enter(a, .caught);
        return false;
    }
    const h = holder(a) orelse {
        a.remove();
        return false;
    };
    const at = movedPlace(a, h);
    e.position.depth = .parts(@intCast(at.depth.whole() + n.juggle_depth), e.position.depth.frac());
    e.position.x = Fixed.parts(@intCast(at.x.whole()), e.position.x.frac()).add(m.offset);
    m.offset = m.offset.add(e.velocity.x);
    if (!m.back) {
        _ = falling(a);
        if (e.position.height.whole() < n.juggle_height) return true;
        if (!walking(a, h)) {
            enter(a, .caught);
            return false;
        }
        m.back = true;
        e.velocity.x = n.juggle_back;
    }
    const hand: i32 = at.x.whole() + if (h.facingLeft()) n.hand_left else n.hand;
    if (hand > e.position.x.whole()) return true;
    const j = juggling(h);
    if (h.mind.juggler.state != .raise) {
        enter(a, .juggled);
        return false;
    }
    if (!j.tossed_first) {
        j.tossed_first = true;
        enter(a, .tossed);
        return false;
    }
    j.caught = true;
    const x: i32 = h.position.x.whole() + if (h.facingLeft()) -@as(i32, n.caught_x) else n.caught_x;
    e.position.x = .parts(@intCast(x), e.position.x.frac());
    enter(a, .flying);
    return false;
}

/// Whether its juggler walks (its walk's animation).
fn walking(a: Actor, h: *const Entity) bool {
    const k = a.tick.kindOf(h);
    const walk = k.definition.animation("walk") orelse return false;
    return h.animation.index == walk;
}

/// A blow on it in its arc makes a copy of it fall away, up and behind its juggler, in the
/// enemies' first free place (none: the weapons' first, as the original's); its own tick ends.
fn copy(a: Actor) void {
    const n = a.numbers();
    const w = a.tick.world;
    const places = world_mod.World.enemy_places;
    const at: fixed.Vec3 = .{ .x = .pixels(a.entity.position.x.whole()), .depth = .pixels(a.entity.position.depth.whole()), .height = .pixels(a.entity.position.height.whole()) };
    const h = w.spawnWithin(a.tick.kinds, a.entity.kind.?, places.from, places.to, at, .right) catch
        w.spawnWithin(a.tick.kinds, a.entity.kind.?, world_mod.World.weapon_places.from, world_mod.World.weapon_places.from + 1, at, .right) catch return;
    const c = w.get(h).?;
    // It moves itself, from its first turn (this tick's, in a place after this one's). In a
    // place before this one's, its first turn is at the next tick, and it is not seen till then:
    // the original draws an object at its turn.
    c.flags.still = true;
    c.flags.hidden = h.index < a.handle.index;
    c.animation = a.entity.animation;
    c.animation.frame = 0;
    c.animation.paused = true;
    c.facing = a.entity.facing;
    c.flags.stays = false;
    c.flags.in_front = a.entity.flags.in_front;
    const k = &c.mind.juggler_knife;
    k.holder = a.mind.holder;
    k.state = .caught;
    k.fresh = true;
    c.velocity.height = n.copy_up;
    const left = if (holder(a)) |j| j.facingLeft() else false;
    c.velocity.x = .pixels(if (left) n.copy_across else -@as(i32, n.copy_across));
}

// Tossed ---------------------------------------------------------------------------------------

fn tossedSetUp(a: Actor) void {
    a.mind.fresh = false;
    a.entity.velocity.height = a.numbers().toss_up;
    a.mind.count = 0;
}

/// Up to its top, where it hangs a while above its juggler; then down to its juggler's hands:
/// caught as its juggler holds its throw's pose, else falling away. False when its state
/// changed.
fn tossed(a: Actor) bool {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (m.count != 0) {
        m.count -= 1;
        return true;
    }
    _ = falling(a);
    const h = holder(a) orelse {
        enter(a, .caught);
        return false;
    };
    if (!m.back) {
        if (e.position.height.whole() > n.toss_top) return true;
        m.back = true;
        e.velocity.height = e.velocity.height.neg();
        const x: i32 = h.position.x.whole() + if (h.facingLeft()) -@as(i32, n.toss_x) else n.toss_x;
        e.position.x = .parts(@intCast(x), e.position.x.frac());
        m.count = n.toss_hang - 1;
        return true;
    }
    if (h.position.height.whole() + n.toss_catch > e.position.height.whole()) return true;
    enter(a, if (throwing(a, h)) .flying else .caught);
    return false;
}

/// Whether its juggler shows its throw.
fn throwing(a: Actor, h: *const Entity) bool {
    const throw = a.tick.kindOf(h).definition.animation("throw") orelse return false;
    return h.animation.index == throw;
}

// Falling away ---------------------------------------------------------------------------------

/// Its gravity, up to its fall's most, then its move in height.
fn falling(a: Actor) bool {
    const n = a.numbers();
    const e = a.entity;
    var v = e.velocity.height.add(.of(a.kind.definition.gravity));
    if (!v.lessThan(n.fall_most) and v.raw >= 0) v = n.fall_most;
    e.velocity.height = v;
    e.position.height = e.position.height.add(v);
    return !a.atGround();
}

/// Falling away: across and in depth by its speed, falling; down, it goes. False when down.
fn falls(a: Actor) bool {
    const e = a.entity;
    e.missile = null;
    e.position.x = e.position.x.add(e.velocity.x);
    e.position.depth = e.position.depth.add(e.velocity.depth);
    return falling(a);
}

// In the hand, in flight --------------------------------------------------------------------------

/// Put in its juggler's hand, its frame held: its juggler holds a knife in hand.
fn flyingSetUp(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    m.fresh = false;
    a.setFrame(0);
    a.pause(true);
    e.missile = null;
    const h = holder(a) orelse return;
    juggling(h).in_hand = true;
    e.position.depth = .parts(@intCast(h.position.depth.whole() + n.hand_depth), e.position.depth.frac());
    e.position.height = .parts(@intCast(h.position.height.whole() + n.hand_height), e.position.height.frac());
    e.facing = h.facing;
    const x: i32 = h.position.x.whole() + if (h.facingLeft()) -@as(i32, n.hand_x) else n.hand_x;
    e.position.x = .parts(@intCast(x), e.position.x.frac());
}

/// In the hand: its juggler's throw's frame sends it off, lower and ahead, straight across, a
/// blow; out of its throw's pose (struck), it falls away.
fn inHand(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const h = holder(a) orelse return turnBack(a);
    if (h.animation.frame == n.launch_frame) {
        m.back = true;
        a.pause(false);
        e.position.height = e.position.height.add(.pixels(n.launch_drop));
        const left = h.facingLeft();
        e.velocity.x = if (left) n.launch_speed.neg() else n.launch_speed;
        e.position.x = e.position.x.add(.pixels(if (left) -@as(i32, n.launch_ahead) else n.launch_ahead));
        e.missile = missile(a);
        return;
    }
    if (!throwing(a, h)) turnBack(a);
}

/// In flight: into the ground, or drawn out of the screen's sides at its last tick (its first in
/// flight: where its juggler's hand held it), it goes; else it flies on. False when it went.
fn flying(a: Actor) bool {
    const n = a.numbers();
    const e = a.entity;
    if (!a.mind.back) return true;
    const from_camera = a.mind.drawn;
    if (a.atGround() or from_camera < n.flight_from or from_camera >= n.flight_to) {
        a.remove();
        return false;
    }
    e.position.x = e.position.x.add(e.velocity.x);
    e.position.depth = e.position.depth.add(e.velocity.depth);
    return true;
}

/// Turned back by a blow: up, the other way across, falling away (sent off once by a swung
/// weapon: at the other player instead).
fn turnBack(a: Actor) void {
    if (a.mind.deflected) return atOtherPlayer(a, null);
    const e = a.entity;
    a.pause(false);
    e.velocity.height = a.numbers().turn_up;
    e.velocity.x = e.velocity.x.neg();
    e.missile = null;
    enter(a, .caught);
    a.mind.ends = true;
}

/// A weapon swung by player `by` meets it in flight: the first time it flies toward the screen's
/// edge it goes away from, at a drawn depth; again, at the other player.
fn deflect(a: Actor, by: Handle) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    m.ends = true;
    if (m.deflected) return atOtherPlayer(a, by);
    m.deflected = true;
    const depth = a.tables().deflect_depth[a.pick(.knife_deflect_depth, 4)];
    var x = a.tick.world.camera.x.whole();
    if (e.velocity.x.raw < 0) x += n.deflect_width;
    const h = fixed.heading(x - e.position.x.whole(), depth - e.position.depth.whole(), n.deflect_speed);
    e.velocity.x = h.x;
    e.velocity.depth = h.depth;
}

/// At the player other than `by` (player 1 when `by` is none), with more power.
fn atOtherPlayer(a: Actor, by: ?Handle) void {
    const n = a.numbers();
    const e = a.entity;
    a.mind.ends = true;
    a.mind.power = n.redirect_power;
    e.missile = missile(a);
    const w = a.tick.world;
    const first = w.players[0].entity;
    const other = if (by != null and first != null and first.?.eql(by.?)) w.players[1].entity else first;
    const o = if (other) |h| w.get(h) else null;
    const tx: i32 = if (o) |t| t.position.x.whole() else 0;
    const td: i32 = if (o) |t| t.position.depth.whole() else 0;
    const h = fixed.heading(tx - e.position.x.whole(), td - e.position.depth.whole(), n.redirect_speed);
    e.velocity.x = h.x;
    e.velocity.depth = h.depth;
}

// The hooks -------------------------------------------------------------------------------------

/// A blow meets it: in its arc, the first tick of a touch makes a copy fall away and ends its
/// tick; in flight, the first turns it back (a weapon a player swings sends it off). The blow
/// lands; a player's not, drawn off the screen's middle at its last tick, nor a thing thrown on
/// it in its arc.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    const m = a.mind;
    const n = a.numbers();
    if (!blow.missile and (m.drawn < n.struck_from or m.drawn >= n.struck_to)) return false;
    switch (m.state) {
        // In its arc a thing thrown, or a weapon swung, does not strike it (the original's knife
        // takes a player's blow only, and its touch ends).
        .juggled => if (blow.missile) return false,
        .flying => if (!m.back) return false,
        else => return false,
    }
    m.touched = true;
    if (m.contact) return true;
    m.contact = true;
    if (m.state == .juggled) {
        copy(a);
        m.ends = true;
        return true;
    }
    if (swungBy(a, blow)) |p| deflect(a, p) else turnBack(a);
    return true;
}

/// The player swinging the weapon that struck, if the blow is a weapon's in a player's swing.
fn swungBy(a: Actor, blow: tick.Blow) ?Handle {
    if (!blow.missile) return null;
    const w = a.other(blow.attacker) orelse return null;
    const p = w.holder orelse return null;
    const pe = a.other(p) orelse return null;
    if (!a.tick.isPlayer(p)) return null;
    const name = @import("../behaviours.zig").stateName(&pe.mind) orelse return null;
    return if (std.mem.eql(u8, name, "armed_swing")) p else null;
}

/// Its blow landed on a player: in flight it is gone.
pub fn blowLanded(a: Actor, target: Handle) void {
    _ = target;
    a.mind.touched = true;
    if (a.mind.state == .flying) a.remove();
}

/// A player's reach meeting it near the player's height is knocked down by it (in flight, it is
/// gone); it is not held.
pub fn grabbable(a: Actor, by: Handle) bool {
    const m = a.mind;
    const live = m.state == .juggled or (m.state == .flying and m.back);
    if (!live) return false;
    // The reach meets it only near the player's height (the original's grab test).
    const p = a.other(by) orelse return false;
    if (@abs(p.position.height.whole() - a.entity.position.height.whole()) > a.numbers().grab_height) return false;
    _ = a.tick.struck(by, .{ .attacker = a.handle, .damage = m.power, .reaction = .knock_down, .push = .zero, .missile = true });
    if (m.state == .flying) a.remove();
    return false;
}
