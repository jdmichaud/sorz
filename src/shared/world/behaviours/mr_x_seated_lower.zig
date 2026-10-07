//! Mr. X's lower part while he sits (mr_x_seated.zig makes it beside him): still, until he
//! stamps (its frames run a while, still a while more, then the floor shakes) or stomps (its next
//! frame a while). Its numbers and frames are its definition's (`entities/mr_x_seated_lower.json`).
const tick = @import("../tick.zig");

const Actor = tick.Actor(@This());

pub const State = enum { start, still, stamping, stamped, stomp, stomping };

pub const trace_states = [_]struct { name: []const u8, state: State }{
    .{ .name = "s0", .state = .start },
    .{ .name = "s1", .state = .still },
    .{ .name = "s2", .state = .stamping },
    .{ .name = "s3", .state = .stamped },
    .{ .name = "s4", .state = .stomp },
    .{ .name = "s5", .state = .stomping },
};

pub const Mind = struct {
    state: State = .start,
    ticks: u16 = 0,
    /// He asked for a stamp.
    stamp: bool = false,
};

pub const Animation = enum { stamp };
pub const Sound = enum { shake };

pub const Numbers = struct {
    stamp_ticks: u16,
    still_ticks: u16,
    stomp_ticks: u16,
};

pub fn think(a: Actor) void {
    const n = a.numbers();
    const m = a.mind;
    a.entity.flags.still = true;
    switch (m.state) {
        .start => {
            a.animate(.stamp);
            a.pause(true);
            m.state = .still;
        },
        .still => if (m.stamp) {
            m.stamp = false;
            a.pause(false);
            m.ticks = n.stamp_ticks;
            m.state = .stamping;
        },
        .stamping => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            m.ticks = n.still_ticks;
            a.pause(true);
            m.state = .stamped;
        },
        .stamped => {
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            // The floor shakes, with its sound, unless it shakes already.
            const c = &a.tick.world.camera;
            if (!a.tick.world.special and c.shake == 0) a.sound(.shake);
            a.tick.shake();
            a.setFrame(0);
            m.state = .still;
        },
        // Its first tick goes on to the next state's.
        .stomp, .stomping => {
            if (m.state == .stomp) {
                m.ticks = n.stomp_ticks;
                a.setFrame(a.frame() + 1);
                m.state = .stomping;
            }
            m.ticks -%= 1;
            if (m.ticks != 0) return;
            a.setFrame(0);
            m.state = .still;
        },
    }
}
