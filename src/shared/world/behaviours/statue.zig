//! A gold statue on its pedestal (round 8's corridor). It stands at its height `height`, its
//! frames held still; from its second tick it is drawn behind what stands at its depth (the
//! original marks it so at each tick but its first). It goes once the camera leaves it behind.
//! One in Mr. X's room (its record's `room_pose`) stands the other way, drawn behind from its
//! first tick.
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

pub const Animation = enum { stand, stand_room };

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
            stand(a);
            e.flags.behind = e.spawn.traits.room_pose;
            m.state = .stand;
        },
        .stand => e.flags.behind = true,
    }
    if (a.tick.behindCamera(e.position.x, a.numbers().left_behind)) a.remove();
}

/// At its height, in its pose.
fn stand(a: Actor) void {
    const e = a.entity;
    e.position.height = .parts(a.numbers().height, e.position.height.frac());
    a.animate(if (e.spawn.traits.room_pose) .stand_room else .stand);
}

/// Taken up from a situation past its first tick (the situation's place is its first): it
/// stands as that tick put it.
pub fn takeUp(a: Actor, elapsed: u32) void {
    _ = elapsed;
    if (a.mind.state == .start) return;
    stand(a);
    a.entity.flags.behind = true;
}
