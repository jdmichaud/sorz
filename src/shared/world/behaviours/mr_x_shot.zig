//! A shot of Mr. X's burst (mr_x.zig fires one at every other frame of his aim), as the traces
//! number its states:
//! - `s0`: its first tick: the gun's sound, its speeds, frame and offsets by its index in the
//!   burst's table (fired to the left: the other way across), at his gun's height;
//! - `s1`: it flies; out of the screen's middle (where it was drawn at the last tick) or deeper
//!   than his depths it goes. It knocks down a player it meets (its power the damage) and an enemy
//!   (`enemy_damage`); a player's
//!   blow knocks it out of the air;
//! - `s2`: knocked out of the air, it falls and bounces on the floor (`bounce`, which a cartridge
//!   shares), and goes.
//! Flying, it hits the others as a thing thrown does. Its numbers, its frames and its sound are
//! its definition's (`entities/mr_x_shot.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const entity = @import("../entity.zig");

const Fixed = fixed.Fixed;
const Handle = entity.Handle;
const Actor = tick.Actor(@This());

pub const State = enum { s0, s1, s2 };

pub const Mind = struct {
    state: State = .s0,
    /// Its index in the burst's table; fired to the left; who fired it.
    index: u8 = 0,
    left: bool = false,
    by: ?Handle = null,
    gravity: Fixed = .zero,
    /// Where it was drawn (from the camera) at the last tick, across and down.
    drawn_x: i16 = 0,
    drawn_y: i16 = 0,
    /// Its state looks for the blows at this tick.
    looks: bool = false,
};

pub const Animation = enum { fly };
pub const Sound = enum { fire };

pub const Numbers = struct {
    /// The table's speeds (words) shifted up so much; its height above his place.
    speed_shift: u5,
    up: i16,
    depth_most: Fixed,
    /// Its blow on a player; on an enemy (as a thing below the weapons' places).
    power: u8,
    enemy_damage: u8,
    /// Knocked out of the air: its speeds an eighth (across turned back), up, its fall, its
    /// frame.
    knocked_shift: u5,
    knocked_up: Fixed,
    knocked_gravity: Fixed,
    knocked_frame: u8,
    bounce_top: i16,
    bounce_floor: i16,
    bounce_least: Fixed,
    bounce_shift: u5,
};

pub const Tables = struct {
    burst_x: [8]u16,
    burst_depth: [8]u16,
    burst_frame: [8]u8,
    burst_offset_x: [8]i8,
    burst_offset_depth: [8]i8,
};

/// What `bounce` reads of the shot's or the cartridge's numbers.
pub const BounceNumbers = struct { top: i16, floor: i16, least: Fixed, shift: u5 };

pub fn begin(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    e.flags.still = true;
    m.looks = false;
    switch (m.state) {
        .s0 => fired(a),
        .s1 => {
            if (!onScreen(m.drawn_x) or n.depth_most.lessThan(e.position.depth)) {
                e.missile = null;
                return a.remove();
            }
            m.looks = true;
        },
        .s2 => if (bounce(e, &m.gravity, m.drawn_x, m.drawn_y, bounceNumbers(n))) return a.remove(),
    }
}

pub fn think(a: Actor) void {
    const m = a.mind;
    const e = a.entity;
    if (m.looks) e.position = e.position.add(e.velocity);
    noteDrawn(a.tick, e, &m.drawn_x, &m.drawn_y);
}

/// A player's blow knocks it out of the air while it flies: its speeds an eighth, back across,
/// up, falling; it hits nothing more.
pub fn struck(a: Actor, blow: tick.Blow) bool {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    if (!m.looks or blow.missile or m.state != .s1) return false;
    e.velocity.x = .{ .raw = (0 -% e.velocity.x.raw) >> n.knocked_shift };
    e.velocity.depth = e.velocity.depth.shr(n.knocked_shift);
    e.velocity.height = n.knocked_up;
    m.gravity = n.knocked_gravity;
    a.setFrame(n.knocked_frame);
    m.state = .s2;
    e.missile = null;
    return true;
}

/// Its first tick: the gun's sound; among the things that hit, its blow its power; its speeds,
/// frame and offsets by its index (to the left the other way across), at his gun's height.
fn fired(a: Actor) void {
    const n = a.numbers();
    const t = a.tables();
    const m = a.mind;
    const e = a.entity;
    a.sound(.fire);
    if (m.by) |by| e.missile = .{ .by = by, .damage = n.enemy_damage, .player_damage = n.power, .on_enemies = true };
    e.facing = if (m.left) .left else .right;
    a.animate(.fly);
    a.pause(true);
    const i = m.index & 7;
    e.velocity = .{ .x = .of(@as(i32, t.burst_x[i]) << n.speed_shift), .depth = .of(@as(i32, t.burst_depth[i]) << n.speed_shift), .height = .zero };
    a.setFrame(t.burst_frame[i]);
    e.position.depth = e.position.depth.add(.pixels(t.burst_offset_depth[i]));
    var dx: i32 = t.burst_offset_x[i];
    if (m.left) {
        dx = -dx;
        e.velocity.x = e.velocity.x.neg();
    }
    e.position.x = e.position.x.add(.pixels(dx));
    e.position.height = e.position.height.sub(.pixels(n.up));
    m.state = .s1;
}

fn bounceNumbers(n: Numbers) BounceNumbers {
    return .{ .top = n.bounce_top, .floor = n.bounce_floor, .least = n.bounce_least, .shift = n.bounce_shift };
}

/// Whether it was drawn in the screen's middle at the last tick (the original's test of its
/// place across).
pub fn onScreen(drawn_x: i16) bool {
    return drawn_x >= 0 and drawn_x < 320;
}

/// The fall of a shot knocked out of the air or of a cartridge: out of the screen's middle it
/// goes (true); drawn at the screen's top, its depth stops; on the floor it bounces back up at
/// part of its speed, or goes once slow; it falls and moves.
pub fn bounce(e: *entity.Entity, gravity: *const Fixed, drawn_x: i16, drawn_y: i16, n: BounceNumbers) bool {
    if (!onScreen(drawn_x)) return true;
    if (drawn_y <= n.top) e.velocity.depth = .zero;
    if (e.position.height.whole() >= n.floor) {
        e.position.height = .pixels(n.floor);
        if (e.velocity.height.lessThan(n.least)) return true;
        e.velocity.height = e.velocity.height.shr(n.shift).neg();
    }
    e.velocity.height = e.velocity.height.add(gravity.*);
    e.position = e.position.add(e.velocity);
    return false;
}

/// Where `e` is drawn now, from the camera, across and down: what its next tick reads.
pub fn noteDrawn(t: *const tick.Tick, e: *const entity.Entity, x: *i16, y: *i16) void {
    if (!e.alive()) return;
    const c = t.world.camera;
    x.* = @truncate(e.position.x.whole() - c.x.whole());
    y.* = @truncate(e.position.screenY() - c.y.whole());
}
