//! A gold statue on its pedestal (round 8's corridor). It stands at its height `height`, its
//! frames held still; from its second tick it is drawn behind what stands at its depth (the
//! original marks it so at each tick but its first). It goes once the camera leaves it behind.
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

pub const Animation = enum { stand };

pub const Numbers = struct {
    height: i16,
    /// It goes this far behind the camera's place across.
    left_behind: i16,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    const m = a.mind;
    e.flags.still = true;
    switch (m.state) {
        .start => {
            e.position.height = .parts(a.numbers().height, e.position.height.frac());
            a.animate(.stand);
            m.state = .stand;
        },
        .stand => e.flags.behind = true,
    }
    if (a.tick.behindCamera(e.position.x, a.numbers().left_behind)) a.remove();
}
