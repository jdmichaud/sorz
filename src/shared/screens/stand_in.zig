//! A stand-in for a scene the game does not have yet: a next round the content does not have
//! (PLAN items 15 and on). It says so on a dark screen, in the game's font, naming the round, and
//! stays.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const art = @import("../content/art.zig");
const setup_mod = @import("../setup.zig");
const Setup = setup_mod.Setup;

pub const StandIn = struct {
    what: flow.Kind,
    ticks: u32 = 0,
    /// The round the game would go on with, as the clear left it.
    round: u8 = 0,

    pub const Assets = struct {
        text: library.Text,
        colours: *const art.Palette,
        pub const names = .{ .text = "fonts/main", .colours = "menu/two_pads" };
    };
    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 } };

    pub fn of(what: flow.Kind, setup: *const Setup) StandIn {
        return .{ .what = what, .round = setup.progress.round };
    }

    pub fn tick(self: *StandIn, turn: *scene.Turn, _: *const Assets) ?flow.Exit {
        self.ticks +|= 1;
        turn.frame = .{};
        if (self.ticks == 1) turn.releasePads();
        return null;
    }

    /// What it says, in capitals (`buf` holds it): "ROUND 3 IS NOT IN THE GAME YET".
    fn line(self: *const StandIn, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        switch (self.what) {
            .next_round => w.print("ROUND {d} IS NOT IN THE GAME YET", .{self.round}) catch {},
            else => {
                for (@tagName(self.what)) |c| w.writeByte(if (c == '_') ' ' else std.ascii.toUpper(c)) catch {};
                w.writeAll(" IS NOT IN THE GAME YET") catch {};
            },
        }
        return w.buffered();
    }

    pub fn draw(self: *const StandIn, prev: ?*const StandIn, v: *view.View, a: *const Assets) !void {
        if (prev == null) {
            var buf: [40]u8 = undefined;
            const text = self.line(&buf);
            const x: i32 = @intCast((40 - text.len) / 2);
            try v.write(.a, a.text, x, 14, text, .{});
        }
        v.screen.colours = @splat(@splat(art.Colour.black));
        a.colours.apply(&v.screen.colours);
    }
};

test "the stand-in names the round the game would go on with" {
    var buf: [40]u8 = undefined;
    const s: StandIn = .{ .what = .next_round, .round = 3 };
    try std.testing.expectEqualStrings("ROUND 3 IS NOT IN THE GAME YET", s.line(&buf));
    const other: StandIn = .{ .what = .high_scores };
    try std.testing.expectEqualStrings("HIGH SCORES IS NOT IN THE GAME YET", other.line(&buf));
}
