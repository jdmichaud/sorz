//! Time (DESIGN.md 10.2, T1, T2, decision D13): which display ticks run the logic, in one place.
//! The display tick is the console's frame, 59.92 a second; presentation, fades and the sound
//! count display ticks. In play the original runs its logic every other display tick (30 a
//! second), and draws what the last logic tick left at each; screens that run at 60 a second
//! run their logic every display tick. It reads the pads at both: its players act on the read of
//! the logic tick's first display tick, with the buttons the read of the display tick before (the
//! last tick's second) had; the read of a logic tick's second display tick counts at the next.
//!
//! `Play` is a round's world on that clock: the scene that plays a round (PLAN item 13) holds it
//! in its state and gives it each display tick's pads, and draws the output's sprites at every
//! display tick. The output, which holds the content by reference, is the presentation's, outside
//! the canonical state. The original's dropped frames (T3, decision D3) would go here; they are
//! not reproduced.
const std = @import("std");
const input = @import("../input.zig");
const random = @import("random.zig");
const world_mod = @import("world.zig");
const kinds_mod = @import("kinds.zig");
const output = @import("output.zig");
const systems = @import("systems.zig");
const tick_mod = @import("tick.zig");
const script = @import("script.zig");

pub const Rate = enum {
    /// Every display tick: the screens that run at 60 a second.
    display,
    /// Every other display tick: play, 30 a second.
    play,
};

pub const Schedule = struct {
    rate: Rate,
    /// The display ticks of the logic tick under way that have passed (play: 0 or 1).
    into: u1 = 0,

    /// A display tick passes: whether a logic tick ends with it (in play, every second one).
    pub fn displayTick(self: *Schedule) bool {
        switch (self.rate) {
            .display => return true,
            .play => {
                if (self.into == 0) {
                    self.into = 1;
                    return false;
                }
                self.into = 0;
                return true;
            },
        }
    }
};

pub const Play = struct {
    world: world_mod.World = .{},
    schedule: Schedule = .{ .rate = .play },
    /// The pads read at the first display tick of the logic tick under way, and at the second
    /// display tick of the last one.
    first: input.Pads = .{},
    second: input.Pads = .{},

    /// One display tick with its pads: at the end of a logic tick, the world's systems run with
    /// the pads its players act on (the last logic tick's second display tick's, then its first
    /// display tick's), and `out` takes the tick's output. Returns whether the logic ran.
    pub fn displayTick(self: *Play, kinds: *const kinds_mod.Kinds, rng: *random.Random, pads: input.Pads, out: *output.Output) bool {
        return self.roundTick(kinds, rng, pads, out, null);
    }

    /// `displayTick` in a round, whose world follows the round's script `plan`.
    pub fn roundTick(self: *Play, kinds: *const kinds_mod.Kinds, rng: *random.Random, pads: input.Pads, out: *output.Output, plan: ?*const script.Plan) bool {
        const due = self.schedule.displayTick();
        if (!due) {
            self.first = pads;
            return false;
        }
        const in: tick_mod.Input = switch (self.schedule.rate) {
            .play => .{ .pads = .{ self.second, self.first } },
            .display => .steady(pads),
        };
        self.second = pads;
        systems.runRound(&self.world, kinds, rng, in, out, plan);
        return true;
    }
};

test "play runs the logic at every other display tick, the screens at each" {
    var s: Schedule = .{ .rate = .play };
    var ran: [6]bool = undefined;
    for (&ran) |*r| r.* = s.displayTick();
    try std.testing.expectEqualSlices(bool, &.{ false, true, false, true, false, true }, &ran);
    var screens: Schedule = .{ .rate = .display };
    for (0..3) |_| try std.testing.expect(screens.displayTick());
}
