//! The acrobats who fight as a trio (round 3's): the acrobat's art and attacks (acrobat.zig's
//! `Attacks`) and every enemy's common states. The first out of hiding leads (role 2) and brings
//! the two others (roles 1 and 0), trio acrobats of their own, beside it (`role_1_beside`,
//! `role_0_beside` ahead), each with its target, health and colours, kept on the screen; the
//! three charge at once.
//!
//! Each takes its place (`take_place`) on its side of the screen's middle, at its target's depth:
//! the leader `leader_out` out from the middle on the side it is on, the others `role_1_out` and
//! `role_0_out` on the leader's side; there it holds (`hold`). Its side changed, it leaps across
//! (`leap_across`); its target near across (`near`), it leaps at it. The three in their places,
//! they pose a while (`pose_ticks`, the knock-down's frame `pose_frame`), then charge at their
//! target (`charge`, at its depth) and attack by their roles when near across: role 0 braces
//! (`brace`) and closes in, role 1 jump kicks and closes in, the leader flips. Out of the fight
//! (a reel, a knock-down...), each takes its place again. A trio broken up (the leader without both
//! its others, another without its leader) leaves acrobats of its own kind.
//!
//! The other program's traces name its first state `start` (`trace_states`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const enemy = @import("enemy.zig");
const acrobat = @import("acrobat.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());
const Common = enemy.Of(@This());
const Attack = acrobat.Attacks(@This());

pub const State = enum {
    appear,
    take_place,
    reel,
    knocked_down,
    stand,
    held,
    knocked_out,
    walk_off,
    charge,
    brace,
    punch,
    jump_kick,
    flip,
    somersault,
    close_in,
    hold,
    leap_across,
};

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "start", .state = .appear },
};

pub const fights: State = .take_place;
/// A somersault's end does not dash back (the original's dash is the acrobat's alone).
pub const somersault_back: ?State = null;

pub const countdowns = [_]State{ .close_in, .stand, .brace };

pub const Mind = struct {
    state: State = .appear,
    body: enemy.Body = .{},
    /// The acrobat's flags (acrobat.zig's `Attacks`).
    back: bool = false,
    fast: bool = false,
    turned: bool = false,
    down: bool = false,
    close_in_after: bool = false,
    /// Its role (2 the leader, 1, 0), the leader, and the leader's others (role 1's, role 0's).
    role: u2 = 2,
    leader: ?Handle = null,
    others: [2]?Handle = .{ null, null },
    /// The leader's: the roles in their places (a bit each), and the side of the screen's middle
    /// the trio takes (left).
    in_place: u3 = 0,
    left: bool = false,
    /// The charge begins with its pose; a leap across at its target (else to its leader's side).
    pose: bool = false,
    at_target: bool = false,
};

pub const Animation = enum { walk, down, reel, stand, thrown, slammed, punch, jump_kick, flip };
pub const Move = enum { punch, somersault, jump_kick };
pub const Sound = enum { hurt, thud, cry, cry_odd, leap, land };

pub const Numbers = enemy.Numbers(struct {
    /// The acrobat's attacks' (acrobat.zig).
    close_in_pace: u8,
    close_in_ticks: u8,
    close_in_speed: Fixed,
    close_in_fast: Fixed,
    close_in_slow: Fixed,
    close_in_beside: i16,
    close_in_level: i16,
    close_in_near: i16,
    punch_ends: u8,
    somersault_x: Fixed,
    somersault_up: Fixed,
    somersault_near: i16,
    somersault_ends: u8,
    jump_kick_up: Fixed,
    jump_kick_x: Fixed,
    flip_up: Fixed,
    flip_x: Fixed,
    back_flip_up: Fixed,
    back_flip_x: Fixed,
    jump_kick_holds: u8,
    flip_holds: u8,
    /// The others brought ahead of the leader: role 1's, role 0's.
    role_1_beside: i16,
    role_0_beside: i16,
    /// The screen's middle (from the camera's left edge), and the places out from it.
    middle: i16,
    leader_out: i16,
    role_1_out: i16,
    role_0_out: i16,
    /// Walking to its place: its frames' pace, its speed.
    place_pace: u8,
    place_speed: Fixed,
    /// Its target this near across, it leaps at it (holding), or closes in (landing).
    near: i16,
    /// The pose: its ticks, its knock-down's frame.
    pose_ticks: u8,
    pose_frame: u8,
    /// The charge: its speed, its frames' pace; how near across each role attacks.
    charge_speed: Fixed,
    charge_pace: u8,
    role_0_near: i16,
    role_1_near: i16,
    leader_near: i16,
    /// The brace's ticks.
    brace_ticks: u8,
    /// The leap across: its speed up, the frame its flip holds from.
    leap_up: Fixed,
    leap_holds: u8,
});

pub const Tables = enemy.Tables(struct {
    /// The leap across's speeds (whole pixels) by its distance to the screen's middle (its low
    /// byte, by quarters of 64).
    leap_speeds: [4]i32,
    /// The offsets from its target by its nibbles' indices (a role 1's: one on in depth).
    offsets: [16]i8,
});

pub fn hurtable(state: State) bool {
    return switch (state) {
        .flip, .leap_across => false,
        else => true,
    };
}

pub fn begin(a: Actor) void {
    if (!Common.setUpDue(a)) return;
    const was = a.mind.state;
    switch (was) {
        .take_place => takePlaceSetUp(a),
        .charge => chargeSetUp(a),
        .brace => braceSetUp(a),
        .hold => holdSetUp(a),
        .leap_across => leapSetUp(a),
        .close_in => Attack.closeInSetUp(a),
        .punch => Attack.punchSetUp(a),
        .somersault => Attack.somersaultSetUp(a),
        .jump_kick => Attack.jumpKickSetUp(a),
        .flip => Attack.flipSetUp(a),
        else => Common.setUp(a),
    }
    _ = Common.leftAt(a, was);
}

pub fn think(a: Actor) void {
    // Broken up at this tick, it is an acrobat of its own already.
    defer if (a.entity.mind == .acrobat_trio) Common.endTick(a);
    if (!Common.tickStarts(a)) return;
    if (a.mind.state == .appear) return start(a);
    if (Common.act(a)) return;
    switch (a.mind.state) {
        .take_place => takePlace(a),
        .charge => charge(a),
        .brace => brace(a),
        .hold => hold(a),
        .leap_across => leap(a),
        .close_in => Attack.closeIn(a),
        .punch => Attack.punch(a),
        .somersault => Attack.somersault(a),
        .jump_kick => Attack.jumpKick(a),
        .flip => Attack.flip(a),
        else => {},
    }
}

fn go(a: Actor, state: State) void {
    Attack.next(a, state, .{});
}

// The trio's making --------------------------------------------------------------------------------

/// Out of hiding with a target, it leads the trio: it brings the two others beside it, each
/// with its target, health and colours, kept on the screen, and all three charge. The others'
/// blows do no damage: the original gives them the leader's health (its record's word with its
/// damage), not its power.
fn start(a: Actor) void {
    if (!Common.comeOut(a)) return;
    if (a.mind.state != fights) return;
    const n = a.numbers();
    a.mind.role = 2;
    a.mind.leader = a.handle;
    go(a, .charge);
    const w = a.tick.world;
    for ([_]u2{ 1, 0 }) |role| {
        var at = a.entity.position;
        at.x = at.x.add(.pixels(if (role == 1) n.role_1_beside else n.role_0_beside));
        // Its offsets from its target one on in depth from the leader's for role 1 (the
        // nibbles' byte, carried as a byte).
        var sp = a.entity.spawn;
        if (sp.offset_nibbles) |b| {
            const nb = b +% role;
            const offsets = a.tables().offsets;
            sp.offset_nibbles = nb;
            sp.offset_x = @as(u8, @bitCast(offsets[nb >> 4]));
            sp.offset_depth = offsets[nb & 0xF];
        }
        const h = w.spawnEnemy(a.tick.kinds, a.entity.kind.?, at, sp) catch break;
        const o = w.get(h).?;
        o.flags.stays = true;
        o.flags.harmless = true;
        o.health = a.entity.health;
        o.palette = a.entity.palette;
        o.mind = .{ .acrobat_trio = .{ .state = .charge, .role = role, .leader = a.handle, .body = .{ .target = a.mind.body.target } } };
        a.mind.others[@intFromBool(role == 0)] = h;
    }
}

/// The leader of its trio, if it is still one of the trio.
fn leaderOf(a: Actor) ?*Mind {
    const h = a.mind.leader orelse return null;
    if (h.eql(a.handle)) return a.mind;
    const e = a.tick.world.get(h) orelse return null;
    return switch (e.mind) {
        .acrobat_trio => |*m| m,
        else => null,
    };
}

/// Its place: at its target's depth, out from the screen's middle (the leader on the side it is
/// on, the others on the leader's).
fn place(a: Actor) void {
    const n = a.numbers();
    const middle = a.tick.world.camera.x.whole() + n.middle;
    const t = Common.target(a) orelse return;
    a.mind.body.dest_depth = .pixels(t.position.depth.whole());
    var out: i32 = undefined;
    if (a.mind.role == 2) {
        a.mind.left = !(middle < a.entity.position.x.whole());
        out = if (a.mind.left) -n.leader_out else n.leader_out;
    } else {
        out = if (a.mind.role == 1) n.role_1_out else n.role_0_out;
        if (leaderOf(a)) |l| {
            if (l.left) out = -out;
        }
    }
    a.mind.body.dest_x = .pixels(middle + out);
}

/// Whether its side of the screen's middle is no longer its trio's: it leaps across.
fn sideChanged(a: Actor) bool {
    const n = a.numbers();
    const middle = a.tick.world.camera.x.whole() + n.middle;
    const left = !(middle < a.entity.position.x.whole());
    const l = leaderOf(a) orelse return false;
    if (l.left == left) return false;
    go(a, .leap_across);
    return true;
}

/// The three in their places: it poses, then charges.
fn trioReady(a: Actor) bool {
    const l = leaderOf(a) orelse return false;
    if (l.in_place != 7) return false;
    go(a, .charge);
    a.mind.pose = true;
    return true;
}

fn markPlace(a: Actor, there: bool) void {
    const l = leaderOf(a) orelse return;
    const bit = @as(u3, 1) << a.mind.role;
    if (there) l.in_place |= bit else l.in_place &= ~bit;
}

// Taking its place, holding it ---------------------------------------------------------------------

fn takePlaceSetUp(a: Actor) void {
    const n = a.numbers();
    if (!Common.chooseTarget(a)) return;
    a.pause(false);
    Common.faceTarget(a);
    a.animate(.walk);
    a.pace(n.place_pace, 1);
    a.setFrame(1);
    a.mind.body.speed = n.place_speed;
    _ = sideChanged(a);
}

fn takePlace(a: Actor) void {
    if (trioReady(a)) return;
    place(a);
    Common.faceTarget(a);
    if (!Common.headForPoint(a)) {
        a.pause(false);
        markPlace(a, false);
        _ = Common.walk(a);
        return;
    }
    // Its place across in whole pixels, its fraction kept.
    a.entity.position.x = .parts(@intCast(a.mind.body.dest_x.whole()), a.entity.position.x.frac());
    a.pause(true);
    a.setTicksLeft(1);
    markPlace(a, true);
    go(a, .hold);
}

fn holdSetUp(a: Actor) void {
    a.pause(true);
    a.setFrame(1);
}

/// It holds its place while the trio holds; its place moved, it walks there again; its side
/// changed, it leaps across; its target near across, it leaps at it.
fn hold(a: Actor) void {
    const n = a.numbers();
    if (trioReady(a)) return;
    if (!intact(a)) return breakUp(a);
    place(a);
    if (!Common.headForPoint(a)) return go(a, .take_place);
    if (sideChanged(a)) return;
    const t = Common.target(a) orelse return;
    if (@abs(a.entity.position.x.whole() - t.position.x.whole()) >= n.near) return;
    go(a, .leap_across);
    a.mind.at_target = true;
}

/// Whether its trio holds: the leader with both its others, another with its leader.
fn intact(a: Actor) bool {
    const w = a.tick.world;
    if (a.mind.role == 2) {
        for (a.mind.others) |o| {
            const h = o orelse return false;
            const e = w.get(h) orelse return false;
            if (e.mind != .acrobat_trio) return false;
        }
        return true;
    }
    return leaderOf(a) != null;
}

/// The trio broken up, it fights on as an acrobat of its own (the acrobat's kind), from the
/// fight's start, its numbers its kind's: a new entity in its place (its handle no longer finds
/// it), as the other program's traces see the original's change of type (a new object in a place
/// freed and taken again).
fn breakUp(a: Actor) void {
    const kind = a.tick.kinds.find("acrobat") orelse return;
    const h = a.handle;
    const body = a.mind.body;
    // Its health and power the trio's again, by its strength (the original sets its numbers
    // anew before its type changes): the others' blows do their damage from now.
    const st = a.entity.spawn.strength;
    const t = a.tables();
    const health = if (st == 0) a.kind.definition.health else t.strength_health[st];
    const power: u8 = if (st == 0) 0 else t.strength_power[st];
    a.tick.world.retype(a.tick.kinds, h, kind);
    const e = a.tick.world.get(h) orelse return;
    var b = body;
    b.fresh = true;
    e.mind = .{ .acrobat = .{ .state = acrobat.fights, .body = b } };
    e.generation +%= 1;
    e.health = health;
    e.power = power;
    e.flags.harmless = false;
}

// The charge ---------------------------------------------------------------------------------------

fn chargeSetUp(a: Actor) void {
    const n = a.numbers();
    if (a.mind.pose) {
        a.pause(true);
        Common.faceTarget(a);
        a.animate(.down);
        a.setFrame(n.pose_frame);
        a.mind.body.timer = n.pose_ticks;
        return;
    }
    if (leaderOf(a)) |l| l.in_place = 0;
    a.pause(false);
    Common.faceTarget(a);
    a.animate(.walk);
    a.entity.velocity.x = if (a.entity.facingLeft()) n.charge_speed.neg() else n.charge_speed;
    a.pace(n.charge_pace, 1);
}

fn charge(a: Actor) void {
    const n = a.numbers();
    if (a.mind.pose) {
        a.mind.body.timer -%= 1;
        if (a.mind.body.timer != 0) return;
        a.mind.pose = false;
        return go(a, .charge);
    }
    _ = Common.walk(a);
    const t = Common.target(a) orelse return;
    a.entity.position.depth = .parts(@intCast(t.position.depth.whole()), a.entity.position.depth.frac());
    const d = @abs(a.entity.position.x.whole() - t.position.x.whole());
    switch (a.mind.role) {
        0 => if (d < n.role_0_near) go(a, .brace),
        1 => if (d < n.role_1_near) {
            go(a, .jump_kick);
            a.mind.close_in_after = true;
        },
        else => if (d < n.leader_near) go(a, .flip),
    }
}

/// Role 0's brace: a while facing its target, then it closes in.
fn braceSetUp(a: Actor) void {
    a.pause(true);
    Common.faceTarget(a);
    a.animate(.walk);
    a.setFrame(1);
    a.mind.body.timer = a.numbers().brace_ticks;
}

fn brace(a: Actor) void {
    Common.conveyed(a);
    a.mind.body.timer -%= 1;
    if (a.mind.body.timer == 0) go(a, .close_in);
}

// The leap across ----------------------------------------------------------------------------------

/// A leap across, at a speed by its distance to the screen's middle, to its trio's side (or at
/// its target); down again it takes its place, or near its target closes in.
fn leapSetUp(a: Actor) void {
    const n = a.numbers();
    a.pause(false);
    Common.faceTarget(a);
    a.animate(.flip);
    a.entity.velocity.height = n.leap_up;
    const middle = a.tick.world.camera.x.whole() + n.middle;
    const d: u32 = @intCast(@abs(middle - a.entity.position.x.whole()) & 0xFF);
    var vx: i32 = a.tables().leap_speeds[d >> 6];
    if (a.mind.at_target) {
        if (a.entity.facingLeft()) vx = -vx;
    } else if (leaderOf(a)) |l| {
        if (l.left) vx = -vx;
    }
    a.mind.at_target = false;
    a.entity.velocity.x = .pixels(@intCast(vx));
}

fn leap(a: Actor) void {
    const n = a.numbers();
    if (!a.entity.animation.paused and a.frame() == n.leap_holds) a.pause(true);
    Common.flyAcross(a);
    if (!Common.falls(a)) return;
    go(a, .take_place);
    const t = Common.target(a) orelse return;
    if (@abs(t.position.x.whole() - a.entity.position.x.whole()) < n.near) go(a, .close_in);
}

// The hooks ----------------------------------------------------------------------------------------

/// Posing, it takes no blow; in a jump kick, the acrobat's way.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    if (a.mind.state == .charge and a.mind.pose) return false;
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

/// Brought back at a wall (enemy.zig's `leftBehind`).
pub fn leftBehind(a: Actor) void {
    Common.leftBehind(a);
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

pub fn takeUpFrame(a: Actor, shown: u32, ago: u32, draws: []const u16) bool {
    return Common.takeUpFrame(a, shown, ago, draws);
}

pub fn takeUpBounces(a: Actor, times: u8) void {
    Common.takeUpBounces(a, times);
}

pub fn takeUpStruck(a: Actor, ago: u32, striking: bool) void {
    Common.takeUpStruck(a, ago, striking);
}
