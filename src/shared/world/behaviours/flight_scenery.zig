//! A piece of scenery a flight stirs (round 2's posters' corners). As it starts it takes the
//! height the round's script gave it, and shows its first frame; one that stirs (its record's
//! trait) flaps while a flight passes (`World.flight`), and keeps the frame it was on when the
//! flight is over. It is drawn behind the others at its depth.
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");

const Actor = tick.Actor(@This());

pub const State = enum { start, stand };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .stand },
};

pub const Mind = struct {
    state: State = .start,
};

pub const Animation = enum { flap };

pub fn think(a: Actor) void {
    const e = a.entity;
    e.flags.still = true;
    e.flags.behind = true;
    switch (a.mind.state) {
        .start => {
            if (e.spawn.height) |h| e.position.height = .parts(h, e.position.height.frac());
            a.pause(true);
            a.animate(.flap);
            a.mind.state = .stand;
        },
        .stand => if (e.spawn.traits.stirs) a.pause(!a.tick.world.flight),
    }
}
