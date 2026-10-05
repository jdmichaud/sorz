//! The baseball bat (round 1 has one in a breakable): a weapon (weapon.zig's body and states)
//! that cannot be thrown. In a player's hand, the first blow it strikes splinters it, at its next
//! tick: from then its poses are the splintered bat's (`broken_` and the pose), and as it
//! splinters it sounds and its splinters (bat_splinter.zig) fly off from its place, up and back
//! from the way it faces, in the items' free places (none free: one is not made). Its numbers,
//! poses and its splinters' speeds are its definition's (`entities/bat.json`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");
const world_mod = @import("../world.zig");
const weapon = @import("weapon.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());
const C = weapon.Of(@This());

pub const State = enum { start, lying, falling, held, blinking_out };

pub const Mind = struct {
    state: State = .start,
    body: weapon.Body = .{},
    /// It is splintered; a blow it struck in a hand splinters it at its next tick.
    splintered: bool = false,
    splinter_due: bool = false,
};

pub const Numbers = struct {
    power: u8,
    uses: u8,
    blink: u8,
    drop: Fixed,
    left_behind: i16,
    /// The splinters it lets off.
    splinters: u8,
};

pub const Tables = struct {
    /// Each splinter's speed up and across (whole pixels a tick; facing right, across the other
    /// way).
    splinter_up: [3]i16,
    splinter_across: [3]i16,
};

pub const Sound = enum { splinter };

/// The kind of its splinters.
pub const splinter_kind = "bat_splinter";

pub fn think(a: Actor) void {
    if (a.mind.state == .held and a.mind.splinter_due and !a.mind.splintered) splinter(a);
    a.mind.splinter_due = false;
    if (C.act(a)) _ = C.leftBehind(a);
}

/// It splinters: its splintered poses from now, its sound, its splinters off its place.
fn splinter(a: Actor) void {
    const n = a.numbers();
    const t = a.tables();
    const e = a.entity;
    a.mind.splintered = true;
    a.sound(.splinter);
    const kind = a.tick.kinds.find(splinter_kind) orelse return;
    const at = e.position;
    const way: i32 = if (e.facingLeft()) 1 else -1;
    const places = world_mod.World.item_places;
    for (0..@min(n.splinters, t.splinter_up.len)) |k| {
        const h = a.tick.world.spawnWithin(a.tick.kinds, kind, places.from, places.to, .{
            .x = .pixels(at.x.whole()),
            .depth = .pixels(at.depth.whole()),
            .height = .pixels(at.height.whole()),
        }, .right) catch return;
        const s = a.tick.world.get(h).?;
        s.velocity = .{ .x = .pixels(t.splinter_across[k] * way), .height = .pixels(t.splinter_up[k]) };
    }
}

/// Splintered, its blow in a hand is the stab, whatever is ahead (the original's B with the bat:
/// the plain blow while whole, the stab once splintered).
pub fn stabs(a: Actor) bool {
    return a.mind.splintered;
}

/// Splintered, its poses are the splintered bat's.
pub fn prefixed(a: Actor) ?[]const u8 {
    return if (a.mind.splintered) "broken_" else null;
}

/// Its blow struck in a hand: it splinters at its next tick.
pub fn blowLanded(a: Actor, target: Handle) void {
    _ = target;
    if (a.mind.state == .held) a.mind.splinter_due = true;
}

pub fn follow(a: Actor) void {
    C.follow(a);
}

pub fn dropped(a: Actor) void {
    C.dropped(a);
}

pub fn putDown(a: Actor) void {
    C.putDown(a);
}

pub fn pickedUp(a: Actor, by: Handle) bool {
    return C.pickedUp(a, by);
}

pub fn takeable(a: Actor) bool {
    return C.takeable(a);
}

pub fn takeUp(a: Actor, elapsed: u32) void {
    C.takeUp(a, elapsed);
}

pub fn takeUpTaken(a: Actor, times: u8) void {
    a.mind.body.taken = times;
}
