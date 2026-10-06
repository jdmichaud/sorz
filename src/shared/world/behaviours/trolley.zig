//! A covered trolley in round 8's corridor. It waits hidden (`wait`) until the camera nears it:
//! once its place is right of the camera's less `ahead`, or, one that rolls in from behind (its
//! record's `rolls` from `from_behind` on), right of the camera's plus `behind`. Then it stands
//! (`stand`) at its height, solid (the fighters' walks stop at its `solid` box,
//! `Tick.keptOut`), with no shadow. One that rolls (`rolls` 1 to 4) rolls across at its
//! `roll_N` speed, with its sound, at the depth and height of a player (player 1 and player 2
//! in turn, `World.trolley_second`; the other when that one is not in the world), striking the
//! players and the enemies its box meets as a thing thrown does (its `power`, knocking down). A
//! blow or a thing thrown on it (on the screen), or a player's grab of one that rolls (the
//! player then struck by it), knocks it away (`flying`, from its next tick), and so does its own
//! blow landing on a player: it leaves the item the round's script gave it (`Tick.give`),
//! sounds, and flies up and across to the side it rolls to, else the one its striker faces; its
//! speed down grows by `rising` while it goes up, `falling` after; on the floor it bounces back
//! up at half its speed, its look running, and at its last meeting with the floor it goes. Left
//! behind the camera, it goes.
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const breakable = @import("breakable.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { wait, stand, flying };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .wait },
    .{ .name = "s1", .state = .stand },
    .{ .name = "s2", .state = .flying },
};

pub const Mind = struct {
    state: State = .wait,
    /// The kind of the item it holds.
    holds: ?entity.KindId = null,
    /// It was on the screen at its last tick's end: a blow lands on it.
    shown: bool = false,
    /// Its meetings with the floor since it was knocked away.
    landings: u8 = 0,
    /// It was knocked away at this tick: its flight starts at its next.
    knocked: bool = false,
};

pub const Animation = enum { stand, fly };
pub const Sound = enum { roll, knocked, bounce };

pub const Numbers = struct {
    /// Its height when it stands.
    height: i16,
    /// How it comes out: rolls from `from_behind` on come from behind, once right of the
    /// camera's place plus `behind`; the others once right of it less `ahead`.
    from_behind: u8,
    behind: i16,
    ahead: i16,
    /// Rolling: its blows' power (on a player), what it does to an enemy (the original's thing
    /// below the weapons' places), its speed across by its rolls.
    power: u8,
    enemy_damage: u8,
    roll_1: Fixed,
    roll_2: Fixed,
    roll_3: Fixed,
    roll_4: Fixed,
    /// Knocked away: its speed up, across to the left and to the right (whole pixels a tick);
    /// what each tick adds to its speed down while it goes up, and after; its meetings with the
    /// floor, the last of which it goes at.
    up: Fixed,
    speed_left: Fixed,
    speed_right: Fixed,
    rising: Fixed,
    falling: Fixed,
    bounces: u8,
    /// It goes this far behind the camera's place across.
    left_behind: i16,
    /// On the screen: its place across less the camera's from `screen_from` up to `screen_to`
    /// (excluded).
    screen_from: i16,
    screen_to: i16,
};

/// Rolling, it moves at the start of its turn, before the blows of the tick meet it (the
/// original's trolley moves, then looks at its hits).
pub fn begin(a: Actor) void {
    if (a.mind.state != .stand) return;
    a.entity.position = a.entity.position.add(a.entity.velocity);
}

pub fn think(a: Actor) void {
    const e = a.entity;
    e.flags.still = true;
    const n = a.numbers();
    switch (a.mind.state) {
        .wait => {
            e.flags.hidden = true;
            if (comesOut(a)) appear(a);
        },
        .stand => {},
        .flying => if (a.mind.knocked) {
            a.mind.knocked = false;
        } else {
            e.velocity.height = e.velocity.height.add(if (e.velocity.height.raw < 0) n.rising else n.falling);
            e.position = e.position.add(e.velocity);
            if (!land(a)) return;
        },
    }
    if (a.tick.behindCamera(e.position.x, n.left_behind)) return a.remove();
    const from_camera = e.position.x.whole() - a.tick.world.camera.x.whole();
    a.mind.shown = from_camera >= n.screen_from and from_camera < n.screen_to;
}

/// Whether the camera has come near enough: its place right of the camera's less `ahead`, or
/// (rolling from behind) plus `behind`, as the original compares their words, unsigned.
fn comesOut(a: Actor) bool {
    const n = a.numbers();
    const camera = a.tick.world.camera.x.whole();
    const edge: u16 = @truncate(@as(u32, @bitCast(if (a.entity.spawn.rolls >= n.from_behind) camera + n.behind else camera - n.ahead)));
    const at: u16 = @truncate(@as(u32, @bitCast(a.entity.position.x.whole())));
    return edge < at;
}

/// It shows: rolling, at its speed with its sound, at a player's depth and height (in turn), its
/// blows striking as a thing thrown does; then solid at its height, its stand.
fn appear(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    const w = a.tick.world;
    e.flags.hidden = false;
    const rolls = e.spawn.rolls;
    if (rolls != 0) {
        a.sound(.roll);
        const speed = switch (rolls) {
            1 => n.roll_1,
            2 => n.roll_2,
            3 => n.roll_3,
            else => n.roll_4,
        };
        e.velocity.x = .parts(@intCast(speed.whole()), e.velocity.x.frac());
        const second = w.trolley_second;
        w.trolley_second = !second;
        const first: u1 = if (second) 1 else 0;
        const k: u1 = if (w.players[first].entity != null) first else 1 - first;
        if (w.players[k].entity) |ph| if (w.getConst(ph)) |p| {
            e.position.depth = p.position.depth;
            e.position.height = p.position.height;
        };
        e.missile = .{ .by = a.handle, .damage = n.enemy_damage, .player_damage = n.power, .on_players = true, .on_enemies = true };
    }
    e.flags.solid = true;
    e.position.height = .parts(n.height, e.position.height.frac());
    a.animate(.stand);
    a.mind.state = .stand;
}

/// A tick of its fall after its move: on the floor it lands at the floor's height, its look
/// running; at its last landing it goes; else it bounces back up at half its speed. False when
/// it went.
fn land(a: Actor) bool {
    const n = a.numbers();
    const e = a.entity;
    const floor = a.tick.floorUnder(e.position) orelse return true;
    if (e.position.height.lessThan(floor)) return true;
    e.position.height = .parts(@intCast(floor.whole()), e.position.height.frac());
    a.pause(false);
    a.mind.landings += 1;
    if (a.mind.landings >= n.bounces) {
        a.remove();
        return false;
    }
    e.velocity.height = .{ .raw = (-%e.velocity.height.raw) >> 1 };
    a.sound(.bounce);
    return true;
}

/// Knocked away to the side it rolls to, else the one `by` faces: its item left, its sound, its
/// speeds' whole pixels (their fractions kept), its flight's look.
fn knock(a: Actor, by: ?*const entity.Entity) void {
    const n = a.numbers();
    const e = a.entity;
    const right = if (e.velocity.x.raw != 0) e.velocity.x.raw > 0 else if (by) |b| !b.facingLeft() else true;
    e.flags.solid = false;
    if (a.mind.holds) |item| {
        a.mind.holds = null;
        breakable.leave(a.tick, item, e.position);
    }
    a.sound(.knocked);
    e.velocity.height = .parts(@intCast(n.up.whole()), e.velocity.height.frac());
    e.velocity.x = .parts(@intCast((if (right) n.speed_right else n.speed_left).whole()), e.velocity.x.frac());
    a.animate(.fly);
    a.mind.state = .flying;
    a.mind.knocked = true;
}

/// A blow or a thing thrown that meets it, standing on the screen, knocks it away.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (a.mind.state != .stand or !a.mind.shown) return false;
    knock(a, a.other(blow.attacker));
    return true;
}

/// Rolling, its blow landing on a player knocks it away too.
pub fn blowLanded(a: Actor, target: Handle) void {
    if (a.mind.state != .stand or a.entity.spawn.rolls == 0) return;
    if (!a.tick.isPlayer(target)) return;
    knock(a, null);
}

/// A player does not hold it; its grab of one that rolls knocks it away, and the player feels
/// the trolley's blow (the original marks the grab's player struck by it).
pub fn grabbable(a: Actor, by: Handle) bool {
    if (a.mind.state != .stand or a.entity.spawn.rolls == 0) return false;
    knock(a, a.other(by));
    _ = a.tick.struck(by, .{ .attacker = a.handle, .damage = a.numbers().power, .reaction = .knock_down, .push = .zero, .missile = true });
    return false;
}

/// The round's script gives it its item.
pub fn given(a: Actor, item: entity.KindId) void {
    a.mind.holds = item;
}
