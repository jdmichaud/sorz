//! A stand-in for a scene the game does not have yet: the attract demo (round 1 played by the
//! game, PLAN item 13 and on), the round's clear and the next round (round 2, PLAN item 15). It says
//! so on a dark screen, in the game's font, and keeps the flow's time and sound: the demo's
//! stand-in plays round 1's music when the demo does, lasts as long as the original's demo and
//! stops the music at its end, so that the high scores come at the original's tick; START on
//! either pad leaves it as the demo's START does, after its fade. The next round's stand-in names
//! the characters chosen, and stays.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const art = @import("../content/art.zig");
const setup_mod = @import("../setup.zig");
const Setup = setup_mod.Setup;

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
    /// The players' characters, as the select left them.
    characters: [2]?setup_mod.Character = .{ null, null },

    pub const Assets = struct {
        text: library.Text,
        colours: *const art.Palette,
        round_1_music: library.Sound,
        stop: library.Sound,
        pub const names = .{ .text = "fonts/main", .colours = "menu/two_pads", .round_1_music = "round 1 music", .stop = "stop" };
    };
    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 } };

    pub fn of(what: flow.Kind, setup: *const Setup) StandIn {
        return .{ .what = what, .characters = setup.characters };
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
            .round_clear => {
                if (self.ticks == 1) turn.releasePads();
                if (self.ticks >= clear_ticks) return .done;
            },
            .next_round => if (self.ticks == 1) turn.releasePads(),
            else => {},
        }
        return null;
    }

    /// The round's clear's stand-in's ticks (its bonuses come in a later commit).
    const clear_ticks = 300;

    /// What it says, a line a row (`buf` holds the characters' names).
    fn lines(self: *const StandIn, buf: []u8) [3][]const u8 {
        return switch (self.what) {
            .demo => .{ "THE ATTRACT DEMO", "PLAYS ROUND 1:", "NOT IN SORZ YET" },
            .round_clear => .{ "ROUND 1 CLEAR", "THE BONUSES ARE", "NOT IN SORZ YET" },
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
