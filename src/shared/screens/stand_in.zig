//! A stand-in for a scene the game does not have yet: the attract demo and play need round 1
//! (PLAN items 11 to 13). It says so on a dark screen, in the game's font, and keeps the flow's
//! time and sound: the demo's stand-in plays round 1's music when the demo does, lasts as long as
//! the original's demo and stops the music at its end, so that the high scores come at the
//! original's tick; START on either pad leaves it as the demo's START does, after its fade. Play's
//! stand-in stops the music, as the round's set-up does, and stays.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const art = @import("../content/art.zig");
const Setup = @import("../setup.zig").Setup;

/// The demo's ticks from its set-up to its last, the load after its set-up left out (sor-remaster:
/// the high scores' set-up 1977 display ticks after the demo's, its load 47 of them).
const demo_ticks = 1930;
/// START during the demo: its fade, then the start-up.
const demo_leave_ticks = 64;

pub const StandIn = struct {
    what: flow.Kind,
    ticks: u32 = 0,
    /// The tick at which START leaves (after the demo's fade).
    leaving_at: ?u32 = null,

    pub const Assets = struct {
        text: library.Text,
        colours: *const art.Palette,
        round_1_music: library.Sound,
        stop: library.Sound,
        pub const names = .{ .text = "fonts/main", .colours = "menu/two_pads", .round_1_music = "round 1 music", .stop = "stop" };
    };
    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 } };

    pub fn of(what: flow.Kind) StandIn {
        return .{ .what = what };
    }

    pub fn tick(self: *StandIn, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.ticks +|= 1;
        turn.frame = .{};
        switch (self.what) {
            .demo => {
                if (self.ticks == 1) turn.releasePads();
                // The demo's music after its load, as the round's set-up asks for it.
                if (self.ticks == 2) turn.play(a.round_1_music);
                if (self.leaving_at) |t| {
                    if (self.ticks >= t) return .start;
                } else if (turn.pressed.pad1.start or turn.pressed.pad2.start) {
                    self.leaving_at = self.ticks + demo_leave_ticks;
                }
                if (self.ticks >= demo_ticks) {
                    turn.play(a.stop);
                    return .done;
                }
            },
            .round => if (self.ticks == 1) {
                turn.releasePads();
                turn.play(a.stop);
            },
            else => {},
        }
        return null;
    }

    /// What it says, a line a row.
    fn lines(self: *const StandIn) [3][]const u8 {
        return switch (self.what) {
            .demo => .{ "THE ATTRACT DEMO", "PLAYS ROUND 1:", "NOT IN SORZ YET" },
            .round => .{ "ROUND 1", "IS NOT IN SORZ YET", "" },
            else => .{ @tagName(self.what), "IS NOT IN SORZ YET", "" },
        };
    }

    pub fn draw(self: *const StandIn, prev: ?*const StandIn, v: *view.View, a: *const Assets) !void {
        if (prev == null) {
            const text = self.lines();
            for (text, 0..) |line, i| {
                var buf: [40]u8 = undefined;
                const upper = std.ascii.upperString(&buf, line[0..@min(line.len, buf.len)]);
                for (upper) |*c| if (c.* == '_') {
                    c.* = ' ';
                };
                const x: i32 = @intCast((40 - upper.len) / 2);
                try v.write(.a, a.text, x, @intCast(12 + 2 * i), upper, .{});
            }
        }
        v.screen.colours = @splat(@splat(art.Colour.black));
        a.colours.apply(&v.screen.colours);
    }
};
