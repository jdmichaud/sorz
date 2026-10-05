//! A lamp (round 3's, on the beach). It stands at its height `height`, drawn behind what stands
//! at its depth, its first frame held still; once the boss's bar shows (the boss's section
//! begun), it is lit: its second frame.
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
};

/// Its frames: unlit, lit.
pub const Animation = enum { lamp };

pub const Numbers = struct {
    height: i16,
};

pub fn think(a: Actor) void {
    const e = a.entity;
    const m = a.mind;
    e.flags.still = true;
    e.flags.behind = true;
    switch (m.state) {
        .start => {
            e.position.height = .parts(a.numbers().height, e.position.height.frac());
            a.pause(true);
            a.animate(.lamp);
            m.state = .stand;
        },
        .stand => if (lit(a)) a.setFrame(1),
    }
}

/// The boss's bar shows, in the boss's section (without a round's script, as in the tests: when
/// it shows).
fn lit(a: Actor) bool {
    const w = a.tick.world;
    if (w.boss_bar == null) return false;
    const p = a.tick.plan orelse return true;
    return script.bossFight(w, p);
}
