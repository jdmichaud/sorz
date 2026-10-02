//! A stand-in for a scene the game does not have yet: the attract demo and play need round 1
//! (PLAN items 11 to 13). It says so on a dark screen, in the game's font, and keeps the flow's
//! time: the demo's stand-in lasts as long as the original's demo, so that what follows it comes
//! at the original's tick; START leaves it where the original's START would.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const art = @import("../content/art.zig");
const Setup = @import("../setup.zig").Setup;

pub const StandIn = struct {
    what: flow.Kind,
    ticks: u32 = 0,

    pub const Assets = struct {
        text: library.Text,
        colours: *const art.Palette,
        pub const names = .{ .text = "fonts/main", .colours = "menu/two_pads" };
    };
    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 } };

    pub fn of(what: flow.Kind) StandIn {
        return .{ .what = what };
    }

    /// How long it lasts before it ends by itself (null: until START, or forever).
    fn lasts(self: *const StandIn) ?u32 {
        return switch (self.what) {
            .round => null,
            else => 120,
        };
    }

    pub fn tick(self: *StandIn, turn: *scene.Turn, _: *const Assets) ?flow.Exit {
        self.ticks +|= 1;
        if (self.what != .round and turn.pressed.pad1.start) return .start;
        if (self.lasts()) |n| if (self.ticks >= n) return .done;
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
