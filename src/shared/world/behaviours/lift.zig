//! Round 7's lift's still pieces (its wall, its floor) and the hidden piece that opens the round's
//! first section. Each takes its place as it starts (`x`, `depth`, `height`) and stays there, its
//! frame held, in front of the layers' cells in front when its definition says so, hidden when it
//! says so. The opener counts `opens_after` ticks, then calls the lift (script.zig `callLift`) and
//! goes.
//!
//! The other program's traces name its states by number (`trace_states`).
const tick = @import("../tick.zig");
const script = @import("../script.zig");

const Actor = tick.Actor(@This());

pub const State = enum { start, stand };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .stand },
};

pub const Mind = struct {
    state: State = .start,
    /// The opener's ticks left.
    ticks: u8 = 0,
};

pub const Animation = enum { lift };

pub const Numbers = struct {
    x: i16,
    depth: i16,
    height: i16,
    /// It is drawn in front of the layers' cells in front (1), hidden (1).
    in_front: u1,
    hidden: u1,
    /// The opener's ticks to the lift's call.
    opens_after: ?u8 = null,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    const m = a.mind;
    const n = a.numbers();
    e.flags.still = true;
    switch (m.state) {
        .start => {
            e.position = .{ .x = .pixels(n.x), .depth = .pixels(n.depth), .height = .pixels(n.height) };
            e.flags.in_front = n.in_front != 0;
            e.flags.hidden = n.hidden != 0;
            a.pause(true);
            a.animate(.lift);
            m.ticks = n.opens_after orelse 0;
            m.state = .stand;
        },
        .stand => if (n.opens_after != null) {
            m.ticks -|= 1;
            if (m.ticks != 0) return;
            script.callLift(a.tick.world);
            a.remove();
        },
    }
}
