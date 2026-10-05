//! A drip (round 2's, from a drain pipe). It hangs at its height `hang` ticks, then swells, a
//! frame `frame_ticks` ticks; it falls, faster each tick, until the floor is `probe` pixels below
//! it; it splashes a frame, shows none a tick, and is made again at its place across, hanging
//! (the far depth: the original's record cleared). Its frames are its behaviour's: its animation
//! holds still.
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");

const Fixed = fixed.Fixed;
const Actor = tick.Actor(@This());

pub const State = enum { start, hang, swell, set_off, fall, splash, again };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .hang },
    .{ .name = "s2", .state = .swell },
    .{ .name = "s3", .state = .set_off },
    .{ .name = "s4", .state = .fall },
    .{ .name = "s5", .state = .splash },
    .{ .name = "s6", .state = .again },
};

pub const Mind = struct {
    state: State = .start,
    /// The ticks left of its frame.
    timer: u8 = 0,
};

/// Its frames: hanging, swelling, falling, the splash, none.
pub const Animation = enum { drip };

pub const Numbers = struct {
    /// The height it hangs at.
    height: i16,
    hang: u8,
    frame_ticks: u8,
    /// Its speed down as it falls, and what each tick adds to it.
    fall: Fixed,
    gravity: Fixed,
    /// It lands when the ground is this far below its place.
    probe: i16,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    const m = a.mind;
    const n = a.numbers();
    e.flags.still = true;
    switch (m.state) {
        .start => {
            e.position.height = .parts(n.height, e.position.height.frac());
            m.timer = n.hang;
            a.pause(true);
            a.animate(.drip);
            m.state = .hang;
        },
        .hang, .swell, .splash => next(a),
        .set_off => {
            e.velocity.height = .parts(@intCast(n.fall.whole()), e.velocity.height.frac());
            m.state = .fall;
        },
        .fall => {
            e.velocity.height = e.velocity.height.add(n.gravity);
            e.position = e.position.add(e.velocity);
            if (e.position.height.whole() + n.probe < a.tick.world.ground.whole()) return;
            m.timer = 1;
            next(a);
        },
        .again => {
            e.position = .{ .x = .pixels(e.position.x.whole()), .depth = .zero, .height = .pixels(n.height) };
            e.velocity = .zero;
            a.animate(.drip);
            m.state = .start;
        },
    }
}

/// The frame's ticks count down; when they run out, the next frame for `frame_ticks` ticks, and
/// the next state.
fn next(a: Actor) void {
    const m = a.mind;
    m.timer -%= 1;
    if (m.timer != 0) return;
    m.timer = a.numbers().frame_ticks;
    a.setFrame(a.frame() + 1);
    m.state = @fromBackingInt(@intCast(@backingInt(m.state) + 1));
}
