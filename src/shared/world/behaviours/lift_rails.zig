//! Round 7's lift's rails. They take their place as they start (`x`, `depth`, `height`), their
//! frame held. While the lift rides (plane B rising: the camera's `Lift.rides`) they run down,
//! `speed` a tick (from their next tick), from height 0 again once at or past `wrap`; they ask for
//! the lift's sound `start` as they begin. When it stops they are back at their height, with the
//! sound `stop`.
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const fixed = @import("../fixed.zig");

const Fixed = fixed.Fixed;
const Actor = tick.Actor(@This());

pub const State = enum { start, waits, runs };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .waits },
    .{ .name = "s2", .state = .runs },
};

pub const Mind = struct {
    state: State = .start,
};

pub const Animation = enum { lift };
pub const Sound = enum { start, stop };

pub const Numbers = struct {
    x: i16,
    depth: i16,
    height: i16,
    speed: Fixed,
    wrap: i16,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    const m = a.mind;
    const n = a.numbers();
    const rides = a.tick.world.camera.lift.rides;
    e.flags.still = true;
    switch (m.state) {
        .start => {
            e.position = .{ .x = .pixels(n.x), .depth = .pixels(n.depth), .height = .pixels(n.height) };
            a.pause(true);
            a.animate(.lift);
            m.state = .waits;
        },
        .waits => if (rides) {
            m.state = .runs;
            a.sound(.start);
        },
        .runs => {
            const h = &e.position.height;
            if (!rides) {
                h.* = .parts(n.height, h.frac());
                m.state = .waits;
                return a.sound(.stop);
            }
            h.* = h.add(n.speed);
            if (h.whole() >= n.wrap) h.* = .parts(0, h.frac());
        },
    }
}
