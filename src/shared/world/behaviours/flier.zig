//! A flier of a flight (flight.zig sends it). At its first tick it takes its size's animation,
//! still; at its second it sets off, down and left and nearer, its wings beating; from then it
//! rises ever faster as it flies, until it is drawn left of `gone_drawn` (its place across on
//! the screen as the drawing kept it at its last tick, `drawn_offset` to the right of the
//! screen's: the original compares it unsigned). While the special attack runs, it only waits,
//! and goes once it was not drawn within the screen's middle (one never drawn goes at once).
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");

const Fixed = fixed.Fixed;
const Actor = tick.Actor(@This());

pub const State = enum { start, set_off, flying, waiting };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .set_off },
    .{ .name = "s2", .state = .flying },
    .{ .name = "s3", .state = .waiting },
};

pub const Mind = struct {
    state: State = .start,
    /// A small one (its flight's table says).
    small: bool = false,
    /// Its place across on the screen as the drawing kept it at its last tick (0: never drawn),
    /// `drawn_offset` to the right of the screen's.
    drawn: u16 = 0,
};

pub const Animation = enum { large, small };

pub const Numbers = struct {
    /// Its speeds as it sets off: down, across, in depth.
    down: Fixed,
    across: Fixed,
    depth: Fixed,
    /// Added to its speed down each tick it flies.
    lift: Fixed,
    drawn_offset: i16,
    /// It goes drawn left of this.
    gone_drawn: u16,
    /// The screen's middle, as drawn: from `middle_from` up to `middle_to` (excluded).
    middle_from: u16,
    middle_to: u16,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    const m = a.mind;
    const n = a.numbers();
    e.flags.still = true;
    if (a.tick.world.special) m.state = .waiting;
    switch (m.state) {
        .start => {
            a.pause(true);
            a.animate(if (m.small) .small else .large);
            m.state = .set_off;
        },
        .set_off => {
            e.velocity.height = .parts(@intCast(n.down.whole()), e.velocity.height.frac());
            e.velocity.x = .parts(@intCast(n.across.whole()), e.velocity.x.frac());
            e.velocity.depth = .parts(@intCast(n.depth.whole()), e.velocity.depth.frac());
            a.pause(false);
            m.state = .flying;
        },
        .flying => {
            if (m.drawn < n.gone_drawn) return a.remove();
            e.velocity.height = e.velocity.height.add(n.lift);
            e.position = e.position.add(e.velocity);
        },
        .waiting => if (m.drawn < n.middle_from or m.drawn >= n.middle_to) return a.remove(),
    }
    m.drawn = @bitCast(@as(i16, @truncate(e.position.x.whole() - a.tick.world.camera.x.whole() + n.drawn_offset)));
}
