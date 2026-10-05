//! The round's clear (DESIGN.md S1; PLAN item 13), after a round won: its planes cleared and the
//! status bar kept, the colours fade in; "ROUND n CLEAR"; the bonuses' lines; then each bonus
//! counted into the scores of the players in play, 100 points a tick with its sound, its line in
//! the counted colours (the time's counts the timer down with it); a wait between the steps.
//! START held from the first count to the counting's end adds what is left at once. Then the
//! screen fades out and the next round follows, the game under way keeping the scores.
//!
//! The bonuses (the original's): the clear's for the round and for each special attack the
//! players in play have left, the time's for each second the timer has left, the level's for
//! the options' LEVEL. What the picture shows is the tick before's, as in play.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const art = @import("../content/art.zig");
const records = @import("../content/screens.zig");
const setup_mod = @import("../setup.zig");
const Colours = @import("colours.zig").Colours;
const round_screen = @import("round.zig");
const Setup = setup_mod.Setup;

/// A step of the clear, each at least a tick: the waits last the record's ticks after their
/// first; a count, until its bonus is counted.
pub const Act = union(enum) {
    fade_in,
    header,
    wait,
    /// A bonus's line, in the normal colours, its digits when it is not zero.
    line: u2,
    /// A bonus's line in the counted colours, with its digits.
    counted: u2,
    count: u2,
    /// A bonus's line again in the normal colours, its own zeros.
    normal: u2,
    fade_out,
    done,
};

/// The steps of rounds 1 to 7 (round 8's lives bonuses come with PLAN item 15).
pub const program = [_]Act{
    .fade_in,        .header,           .wait,            .{ .line = 0 },   .{ .line = 1 },    .{ .line = 2 },
    .wait,           .{ .counted = 0 }, .{ .count = 0 },  .wait,            .{ .normal = 0 },  .{ .counted = 1 },
    .wait,           .{ .count = 1 },   .wait,            .{ .normal = 1 }, .{ .counted = 2 }, .wait,
    .{ .count = 2 }, .wait,             .{ .normal = 2 }, .wait,            .wait,             .fade_out,
    .done,
};

/// The step from which START held adds the bonuses at once, and the one it goes to.
const skip_from = 7;
const skip_to = 21;

/// What a bonus's line shows: nothing, its text in the normal or the counted colours, and its
/// digits (null: the text's own zeros).
pub const Line = struct {
    shown: bool = false,
    counted: bool = false,
    digits: ?u32 = null,
};

/// What the picture shows.
pub const Shown = struct {
    header: bool = false,
    lines: [3]Line = @splat(.{}),
    bar: round_screen.Bar = .{},
};

pub const RoundClear = struct {
    act: u8 = 0,
    /// A wait runs, and its ticks left.
    waiting: bool = false,
    left: u8 = 0,
    set_up: bool = false,
    /// The round cleared.
    round: u8 = 1,
    /// The bonuses left to count.
    bonuses: [3]u32 = .{ 0, 0, 0 },
    /// The bonus a count draws the digits of at each tick.
    counting: ?u2 = null,
    now: Shown = .{},
    shown: Shown = .{},
    colours: Colours = .{},

    pub const Assets = struct {
        screen: *const records.Round,
        header: *const art.TileMap,
        end_colours: *const art.Palette,
        players_colours: *const art.Palette,
        status_bar: *const art.TileMap,
        time_digits: *const art.TileMap,
        health_1: *const art.TileMap,
        health_2: *const art.TileMap,
        police_icon: *const art.TileMap,
        fills: *const art.TileSheet,
        text: library.Text,
        music: library.Sound,
        tick: library.Sound,
        pub const names = .{
            .screen = "screens/round",
            .header = "round_end/header",
            .end_colours = "round_end/colours",
            .players_colours = "play/players",
            .status_bar = "play/status_bar",
            .time_digits = "play/time_digits",
            .health_1 = "play/health_1",
            .health_2 = "play/health_2",
            .police_icon = "play/police_icon",
            .fills = "play/fills",
            .text = "fonts/main",
            .music = "round clear music",
            .tick = "bonus tick",
        };
    };

    pub const layout: view.Layout = .{
        .a = .{ .width = 64, .height = 32 },
        .window = .{ .width = 40, .height = 4 },
    };

    pub fn start(_: *const Setup) RoundClear {
        return .{};
    }

    /// One display tick.
    pub fn tick(self: *RoundClear, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.colours.latch();
        self.shown = self.now;
        if (!self.set_up) {
            turn.releasePads();
            self.setUp(turn, a);
            return null;
        }
        const c = &a.screen.clear;
        const g = &turn.setup.progress;
        if (self.act >= skip_from and self.act < skip_to and startHeld(turn, g)) self.skip(g, a);
        switch (program[self.act]) {
            .fade_in, .fade_out => if (self.colours.stepFade()) self.next(),
            .header => {
                self.now.header = true;
                self.next();
            },
            .wait => if (!self.waiting) {
                self.waiting = true;
                self.left = c.wait;
            } else {
                self.left -|= 1;
                if (self.left == 0) {
                    self.waiting = false;
                    self.next();
                }
            },
            .line => |k| {
                self.now.lines[k] = .{ .shown = true, .digits = if (self.bonuses[k] != 0) self.bonuses[k] else null };
                self.next();
            },
            .counted => |k| {
                self.now.lines[k] = .{ .shown = true, .counted = true, .digits = self.bonuses[k] };
                self.next();
            },
            .normal => |k| {
                self.now.lines[k] = .{ .shown = true };
                self.next();
            },
            .count => |k| {
                if (k == 1 and g.timer != 0) {
                    g.timer -= 1;
                    turn.play(a.tick);
                }
                if (self.bonuses[k] == 0) {
                    self.counting = null;
                    self.next();
                } else {
                    const n = @min(c.count, self.bonuses[k]);
                    self.bonuses[k] -= n;
                    self.counting = k;
                    for (&g.players) |*p| if (p.in_play) addScore(p, n, a);
                    turn.play(a.tick);
                    self.now.lines[k].digits = self.bonuses[k];
                }
            },
            .done => {
                g.round += 1;
                return .done;
            },
        }
        self.now.bar = barOf(g);
        return null;
    }

    fn next(self: *RoundClear) void {
        self.act += 1;
        if (program[self.act] == .fade_out) self.colours.startFade(.black);
    }

    /// START held on the pad of a player in play.
    fn startHeld(turn: *const scene.Turn, g: *const setup_mod.Progress) bool {
        if (g.players[0].in_play and turn.pads.pad1.start) return true;
        if (g.players[1].in_play and turn.pads.pad2.start) return true;
        return false;
    }

    /// START held: what is left of the bonuses goes to the scores at once, the lines show them
    /// all, and the counting ends.
    fn skip(self: *RoundClear, g: *setup_mod.Progress, a: *const Assets) void {
        var left: u32 = 0;
        for (self.bonuses) |b| left += b;
        for (&g.players) |*p| if (p.in_play) addScore(p, left, a);
        for (&self.now.lines, self.bonuses) |*l, b| l.* = .{ .shown = true, .digits = if (b != 0) b else null };
        self.counting = null;
        self.act = skip_to;
        self.left = 0;
        self.waiting = false;
    }

    /// The set-up: the bonuses from the game under way, the colours to fade in (the status
    /// bar's and the clear's), its music.
    fn setUp(self: *RoundClear, turn: *scene.Turn, a: *const Assets) void {
        const c = &a.screen.clear;
        const g = &turn.setup.progress;
        var specials: u32 = 0;
        for (g.players) |p| if (p.in_play) {
            specials += p.specials;
        };
        self.bonuses = .{
            c.clear_bonus * (1 + specials),
            c.time_bonus * g.timer,
            c.level_bonus * turn.setup.level,
        };
        self.colours.palettes = .{};
        self.colours.aim(a.players_colours);
        self.colours.aim(a.end_colours);
        self.colours.startFade(.target);
        self.now.bar = barOf(g);
        self.round = g.round;
        self.set_up = true;
        turn.play(a.music);
    }

    pub fn draw(self: *const RoundClear, prev: ?*const RoundClear, v: *view.View, a: *const Assets) !void {
        const was: ?*const Shown = if (prev) |p| &p.shown else null;
        const s = &self.shown;
        const c = &a.screen.clear;
        const board = v.board(.a);
        if (prev == null) {
            try v.board(.window).drawMapAtPlace(a.status_bar);
            try round_screen.drawBar(v, a, s.bar, null);
        } else try round_screen.drawBar(v, a, s.bar, was.?.bar);
        if (s.header and (was == null or !was.?.header)) {
            try board.drawMap(a.header, c.header_at.x, c.header_at.y);
            const at: records.Cell = .{ .x = c.header_at.x + c.number.x, .y = c.header_at.y + c.number.y };
            // The round's number: a big digit in the header's colours.
            const d: usize = @min(self.round, 9);
            for (0..2) |row| {
                const cell = a.time_digits.cell(d, row);
                try board.put(at.x, at.y + @as(i32, @intCast(row)), &a.time_digits.tiles[cell.tile], .{ .palette = c.normal, .priority = true });
            }
        }
        for (s.lines, 0..) |l, k| {
            if (was) |w| if (std.meta.eql(w.lines[k], l)) continue;
            if (!l.shown) continue;
            try drawLine(v, a, k, l);
        }
        v.screen.plane_a.x = 0;
        v.screen.plane_a.y = 0;
        v.screen.window.lines = .{ .top = 0, .bottom = 32 };
        v.screen.colours = self.colours.shown;
    }
};

/// A bonus's line: its text in its colours, its digits over the text's zeros.
fn drawLine(v: *view.View, a: *const RoundClear.Assets, k: usize, l: Line) !void {
    const c = &a.screen.clear;
    const line = c.lines[k];
    const look: render.Look = .{ .palette = if (l.counted) c.counted else c.normal };
    try v.write(.a, a.text, line.at.x, line.at.y, line.text, look);
    if (l.digits) |d| {
        // As many digits as the line's zeros there.
        var width: u8 = 0;
        while (c.digits + width < line.text.len and line.text[c.digits + width] == '0') width += 1;
        var buf: [10]u8 = undefined;
        try v.write(.a, a.text, line.at.x + c.digits, line.at.y, round_screen.digits(&buf, d, width), look);
    }
}

/// `points` to a player's score, which holds at the most a score holds (play's record's).
fn addScore(p: *setup_mod.Gamer, points: u32, a: *const RoundClear.Assets) void {
    p.score = @min(p.score + points, a.screen.status_bar.score_most);
}

/// The status bar of the game under way: the players in play's parts, the timer.
fn barOf(g: *const setup_mod.Progress) round_screen.Bar {
    var b: round_screen.Bar = .{ .time = g.timer };
    for (g.players, &b.players) |p, *o| {
        if (!p.in_play) continue;
        o.* = .{ .playing = .{ .score = p.score, .lives = p.lives, .specials = p.specials, .health = p.health } };
    }
    return b;
}

test "the steps: a wait is its first tick and the record's ticks" {
    try std.testing.expect(program[0] == .fade_in and program[program.len - 1] == .done);
    try std.testing.expect(program[skip_to] == .wait and program[skip_from] == .counted);
}
