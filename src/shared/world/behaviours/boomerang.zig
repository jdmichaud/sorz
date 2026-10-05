//! Antonio's boomerang (antonio.zig gets one when he has none in hand):
//! - `in_hand`: it shows in his hand where his frame says (`Frame.hand`: across from him, up,
//!   its pose), unseen and still in his frames without it; at the frame that holds it out ahead
//!   (its pose `spin`) it is thrown, flying his way;
//! - `out`: it flies, slowing across, swinging in depth, a while; then it turns, still;
//! - `back`: it comes back, faster and faster across, to a depth it heads for, until he catches
//!   it in his hand (antonio.zig) or it leaves the screen far off;
//! - `dropped`: struck by a player's blow on the screen, it is knocked up and away, and soon
//!   gone.
//! Flying, it is a thing thrown: its blow is his power and knocks down, on the players. It goes
//! when he goes. Its numbers, poses and sounds are its definition's (`entities/boomerang.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { in_hand, out, back, dropped };

pub const Mind = struct {
    state: State = .in_hand,
    /// Antonio's place in the world (the original's boomerang follows the place, not him).
    thrower: u8 = 0,
    /// His power, its blow's damage; his ground, below which it does not go.
    power: u8 = 0,
    ground: Fixed = .zero,
    /// Thrown his way right; its flight's ticks left (dropped: its ticks left).
    right: bool = false,
    ticks: u8 = 0,
    /// Coming back: the depth it heads for, and whether that is above it.
    point_depth: i16 = 0,
    above: bool = false,
    /// Where it was drawn across the screen at the last tick; struck at this tick.
    drawn: i16 = 0,
    ended: bool = false,
};

pub const Animation = enum { held, held_high, spin };
pub const Sound = enum { whirr, dropped };

pub const Numbers = struct {
    /// Thrown: its speed across and in depth, the ticks it flies out; slowing across and in
    /// depth each tick (coming back, its step toward its depth, and how near is there).
    flight_speed: Fixed,
    flight_depth: Fixed,
    flight_ticks: u8,
    slowing: Fixed,
    depth_slowing: Fixed,
    depth_back: Fixed,
    depth_within: u16,
    depth_most: i16,
    /// Coming back, it goes drawn beyond these; a blow lands on it drawn within these.
    gone_from: i16,
    gone_to: i16,
    struck_from: i16,
    struck_to: i16,
    /// Dropped: its ticks, its speeds up and in depth, its speed across turned back and shifted
    /// down so much.
    dropped_ticks: u8,
    dropped_up: Fixed,
    dropped_depth: Fixed,
    dropped_back: u5,
};

/// Its thrower, while he is in his place.
fn thrower(a: Actor) ?*entity.Entity {
    const h = a.tick.world.handleAt(a.mind.thrower) orelse return null;
    return a.other(h);
}

pub fn begin(a: Actor) void {
    a.mind.ended = false;
    a.entity.flags.still = true;
}

pub fn think(a: Actor) void {
    const m = a.mind;
    // It goes when he does.
    if (thrower(a) == null) return a.remove();
    if (!m.ended) switch (m.state) {
        .in_hand => inHand(a),
        .out => out(a),
        .back => back(a),
        .dropped => {
            m.ticks -%= 1;
            if (m.ticks == 0) return a.remove();
            move(a);
        },
    };
    if (!a.entity.alive()) return;
    if (!a.entity.flags.hidden) m.drawn = @intCast(a.entity.position.x.whole() - a.tick.world.camera.x.whole());
}

/// In his hand: where his frame holds it (its fractions kept), in the frame's pose; unseen and
/// still in a frame without it; thrown at the frame that holds it out.
fn inHand(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const him = thrower(a).?;
    // Shown it takes a shadow's place (world/shadows.zig), hidden none.
    e.flags.hidden = false;
    e.flags.shadowless = false;
    const f = a.tick.frameOf(him);
    const h = (if (f) |x| x.hand else null) orelse {
        e.flags.hidden = true;
        e.flags.shadowless = true;
        return;
    };
    e.position.x = .parts(@intCast(him.position.x.whole() + @as(i32, h.x) * him.facing.sign()), e.position.x.frac());
    e.position.depth = .parts(@intCast(him.position.depth.whole()), e.position.depth.frac());
    e.position.height = .parts(@intCast(him.position.height.whole() + h.height), e.position.height.frac());
    const pose = poseOf(h.pose);
    if (a.plays(pose) and e.facing == him.facing) return;
    e.facing = him.facing;
    if (pose == .spin) {
        m.right = him.facing == .right;
        e.velocity.x = if (m.right) n.flight_speed else n.flight_speed.neg();
        e.velocity.depth = n.flight_depth;
        m.state = .out;
        m.ticks = n.flight_ticks;
        a.sound(.whirr);
        e.missile = .{ .by = a.tick.world.handleAt(m.thrower).?, .damage = m.power };
    }
    a.animate(pose);
}

fn poseOf(name: []const u8) Animation {
    return std.meta.stringToEnum(Animation, name) orelse .held;
}

/// Its speed across, slowing toward his side (thrown right, it slows by going left).
fn slow(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    e.velocity.x = if (a.mind.right) e.velocity.x.sub(n.slowing) else e.velocity.x.add(n.slowing);
}

/// Flying out: it slows across and swings in depth; its flight over, it turns, still, to head
/// for depth 0 (the original's misread of its target's depth).
fn out(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    slow(a);
    e.velocity.depth = e.velocity.depth.add(n.depth_slowing);
    m.ticks -%= 1;
    if (m.ticks == 0) {
        m.point_depth = 0;
        m.above = e.position.depth.whole() > 0;
        e.velocity.x = .zero;
        e.velocity.depth = .zero;
        m.state = .back;
        a.sound(.whirr);
    }
    move(a);
}

/// Coming back: faster across, toward its depth until near it; far off the screen it goes.
fn back(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    slow(a);
    if (@abs(e.position.depth.whole() - m.point_depth) < n.depth_within) {
        e.velocity.depth = .zero;
    } else {
        e.velocity.depth = if (m.above) e.velocity.depth.sub(n.depth_back) else e.velocity.depth.add(n.depth_back);
    }
    if (m.drawn < n.gone_from or m.drawn >= n.gone_to) return a.remove();
    move(a);
}

/// It moves by its speeds (as he does): in depth within the depths, down no further than his
/// ground.
fn move(a: Actor) void {
    const n = a.numbers();
    const e = a.entity;
    e.position.x = e.position.x.add(e.velocity.x);
    var d = e.position.depth.add(e.velocity.depth);
    if (d.raw < 0) d = .zero;
    if (!d.lessThan(.pixels(n.depth_most))) d = .pixels(n.depth_most);
    e.position.depth = d;
    const h = e.position.height.add(e.velocity.height);
    const ground = a.mind.ground;
    e.position.height = if (@as(u32, @bitCast(h.raw)) > @as(u32, @bitCast(ground.raw))) ground else h;
}

/// Taken up from a situation, `elapsed` ticks into its state (its thrower takes it up as his):
/// thrown his way as it faces; flying out, its flight gone on since; dropped, its ticks too.
pub fn takeUp(a: Actor, elapsed: u32) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    const ago: u8 = @intCast(@min(elapsed, 255));
    m.drawn = @intCast(e.position.x.whole() - a.tick.world.camera.x.whole());
    // Thrown his way: flying out it goes that way, coming back the other; at its turn, still, it
    // is on that side of him.
    const vx = e.velocity.x.raw;
    m.right = switch (m.state) {
        .out => vx > 0,
        .back => if (vx != 0) vx < 0 else if (thrower(a)) |him| e.position.x.whole() > him.position.x.whole() else true,
        else => e.facing == .right,
    };
    if (m.state == .out or m.state == .back) {
        e.facing = if (m.right) .right else .left;
        a.animate(.spin);
    }
    switch (m.state) {
        .out => m.ticks = n.flight_ticks -| ago,
        .back => m.above = a.entity.position.depth.whole() > 0,
        .dropped => m.ticks = n.dropped_ticks -| ago,
        .in_hand => {},
    }
}

/// A blow meets it flying, on the screen: a player's drops it (its tick ends there); a thing
/// thrown does not.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (blow.missile) return false;
    if (m.state != .out and m.state != .back) return false;
    if (m.drawn < n.struck_from or m.drawn >= n.struck_to) return false;
    m.ticks = n.dropped_ticks;
    e.velocity.height = .parts(@intCast(n.dropped_up.whole()), e.velocity.height.frac());
    e.velocity.depth = .parts(@intCast(n.dropped_depth.whole()), e.velocity.depth.frac());
    e.velocity.x = .{ .raw = -(e.velocity.x.raw >> n.dropped_back) };
    m.state = .dropped;
    e.missile = null;
    a.sound(.dropped);
    m.ended = true;
    return true;
}
