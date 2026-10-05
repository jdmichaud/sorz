//! A stand-in for a scene the game does not have yet: the next round (round 2, PLAN item 15). It
//! says so on a dark screen, in the game's font, naming the characters chosen, and stays.
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
    /// The players' characters, as the select left them.
    characters: [2]?setup_mod.Character = .{ null, null },

    pub const Assets = struct {
        text: library.Text,
        colours: *const art.Palette,
        pub const names = .{ .text = "fonts/main", .colours = "menu/two_pads" };
    };
    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 } };

    pub fn of(what: flow.Kind, setup: *const Setup) StandIn {
        return .{ .what = what, .characters = setup.characters };
    }

    pub fn tick(self: *StandIn, turn: *scene.Turn, _: *const Assets) ?flow.Exit {
        self.ticks +|= 1;
        turn.frame = .{};
        if (self.ticks == 1) turn.releasePads();
        return null;
    }

    /// What it says, a line a row (`buf` holds the characters' names).
    fn lines(self: *const StandIn, buf: []u8) [3][]const u8 {
        return switch (self.what) {
            .next_round => .{ "ROUND 2 WITH", self.names(buf), "IS NOT IN SORZ YET" },
            else => .{ @tagName(self.what), "IS NOT IN SORZ YET", "" },
        };
    }

    /// The characters chosen: "AXEL", or "ADAM AND BLAZE".
    fn names(self: *const StandIn, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        var first = true;
        for (self.characters) |c| if (c) |who| {
            if (!first) w.writeAll(" AND ") catch {};
            first = false;
            w.writeAll(@tagName(who)) catch {};
        };
        return w.buffered();
    }

    pub fn draw(self: *const StandIn, prev: ?*const StandIn, v: *view.View, a: *const Assets) !void {
        if (prev == null) {
            var names_buf: [40]u8 = undefined;
            const text = self.lines(&names_buf);
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
