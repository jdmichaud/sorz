//! A cartridge of Mr. X's gun (mr_x.zig makes one with each shot, flying the other way, and
//! spills them in his last fall), as the traces number its states:
//! - `s0`: its first tick: spinning, its speeds by its index in the burst's table (smaller than
//!   the shot's; to the left the other way across): out of his gun at his gun's height, up and
//!   falling fast; spilled, at half the speeds, up and falling slowly;
//! - `s1`: it falls and bounces on the floor as a shot knocked out of the air does
//!   (mr_x_shot.zig's `bounce`), and goes.
//! Its numbers and its frames are its definition's (`entities/mr_x_cartridge.json`).
const std = @import("std");
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");
const shot = @import("mr_x_shot.zig");

const Fixed = fixed.Fixed;
const Actor = tick.Actor(@This());

pub const State = enum { s0, s1 };

pub const Mind = struct {
    state: State = .s0,
    /// Its index in the burst's table; flying to the left; spilled in his fall.
    index: u8 = 0,
    left: bool = false,
    spilled: bool = false,
    gravity: Fixed = .zero,
    /// Where it was drawn (from the camera) at the last tick, across and down.
    drawn_x: i16 = 0,
    drawn_y: i16 = 0,
};

pub const Animation = enum { spin };

pub const Numbers = struct {
    shift_x: u5,
    shift_depth: u5,
    up: i16,
    gun_up: Fixed,
    gun_gravity: Fixed,
    fall_up: Fixed,
    fall_gravity: Fixed,
    bounce_top: i16,
    bounce_floor: i16,
    bounce_least: Fixed,
    bounce_shift: u5,
};

pub const Tables = struct {
    burst_x: [8]u16,
    burst_depth: [8]u16,
};

pub fn begin(a: Actor) void {
    a.entity.flags.still = true;
}

pub fn think(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    const e = a.entity;
    switch (m.state) {
        .s0 => thrownOut(a),
        .s1 => if (shot.bounce(e, &m.gravity, m.drawn_x, m.drawn_y, .{ .top = n.bounce_top, .floor = n.bounce_floor, .least = n.bounce_least, .shift = n.bounce_shift })) return a.remove(),
    }
    shot.noteDrawn(a.tick, e, &m.drawn_x, &m.drawn_y);
}

/// Its first tick: spinning (its frames its own, whatever the way), its speeds by its index; out
/// of his gun at his gun's height, up and falling fast; spilled, at half its speeds, up and
/// falling slowly.
fn thrownOut(a: Actor) void {
    const n = a.numbers();
    const t = a.tables();
    const m = a.mind;
    const e = a.entity;
    e.facing = .right;
    a.pause(false);
    a.animate(.spin);
    const i = m.index & 7;
    e.velocity = .{ .x = .of(@as(i32, t.burst_x[i]) << n.shift_x), .depth = .of(@as(i32, t.burst_depth[i]) << n.shift_depth), .height = .zero };
    if (m.left) e.velocity.x = e.velocity.x.neg();
    m.state = .s1;
    if (!m.spilled) {
        e.position.height = e.position.height.sub(.pixels(n.up));
        e.velocity.height = n.gun_up;
        m.gravity = n.gun_gravity;
        return;
    }
    e.velocity.x = e.velocity.x.shr(1);
    e.velocity.depth = e.velocity.depth.shr(1);
    e.velocity.height = n.fall_up;
    m.gravity = n.fall_gravity;
}
