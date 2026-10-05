//! The high scores, after the attract demo, a game over and the good ending: THE BEST 10 PLAYERS,
//! the table sorted and drawn at once (a new entry in its player's colours, once), the name entry
//! music, then 600 ticks or START on either pad, and the Sega logo again. No fade: the screen
//! cuts from dark to the table and from the table to dark.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const art = @import("../content/art.zig");
const records = @import("../content/screens.zig");
const setup_mod = @import("../setup.zig");
const Setup = setup_mod.Setup;
const Score = setup_mod.Score;
const Colours = @import("colours.zig").Colours;

const shown_ticks = 600;

/// Where an entry's parts go: its row (two rows an entry from the first), each part's column and
/// cells.
const first_row = 7;
const score_column = 10;
const round_column = 19;
const name_column = 25;
const level_column = 32;
const level_cells = 7;

pub const HighScores = struct {
    ticks: u16 = 0,
    colours: Colours = .{},
    /// The table, sorted, as it is shown (with its new entries marked).
    table: [setup_mod.high_scores]Score = @splat(.{}),
    left: u16 = 0,

    pub const Assets = struct {
        title: *const art.TileMap,
        columns: *const art.TileMap,
        ranks: *const art.TileMap,
        colours: *const art.Palette,
        text: library.Text,
        first: *const records.HighScores,
        options: *const records.Options,
        music: library.Sound,
        pub const names = .{
            .title = "highscores/title",
            .columns = "highscores/columns",
            .ranks = "highscores/ranks",
            .colours = "highscores/colours",
            .text = "fonts/main",
            .first = "screens/high_scores",
            .options = "screens/options",
            .music = "name entry music",
        };
    };

    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 } };

    pub fn start(_: *const Setup) HighScores {
        return .{};
    }

    pub fn tick(self: *HighScores, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.ticks +|= 1;
        self.colours.latch();
        defer turn.frame = .{ .colours = self.colours.copy, .play = true };
        if (self.ticks == 1) {
            turn.releasePads();
            self.colours.show(a.colours);
            var table = turn.setup.high_scores orelse firstTable(a.first);
            sort(&table);
            self.table = table;
            // The new entries are coloured once.
            for (&table) |*e| e.new = null;
            turn.setup.high_scores = table;
            turn.play(a.music);
            self.left = shown_ticks;
            return null;
        }
        self.left -= 1;
        if (self.left == 0) return .done;
        if (turn.pressed.pad1.start or turn.pressed.pad2.start) return .start;
        return null;
    }

    /// The content's table, as the game keeps it.
    fn firstTable(first: *const records.HighScores) [setup_mod.high_scores]Score {
        var t: [setup_mod.high_scores]Score = @splat(.{});
        for (first.first[0..@min(first.first.len, t.len)], 0..) |e, i| {
            t[i] = .{ .score = e.score, .round = e.round, .level = e.level };
            @memcpy(&t[i].name, e.name[0..3]);
        }
        return t;
    }

    /// The best first: a higher score, or the same and a higher level, or both the same and a
    /// higher round. As the original sorts: each entry swapped with each later one that beats it.
    pub fn sort(t: []Score) void {
        for (0..t.len) |i| for (i + 1..t.len) |j| {
            if (beats(t[j], t[i])) std.mem.swap(Score, &t[i], &t[j]);
        };
    }

    fn beats(a: Score, b: Score) bool {
        if (a.score != b.score) return a.score > b.score;
        if (a.level != b.level) return a.level > b.level;
        return a.round > b.round;
    }

    pub fn draw(self: *const HighScores, prev: ?*const HighScores, v: *view.View, a: *const Assets) !void {
        if (prev == null or !std.meta.eql(prev.?.table, self.table)) {
            const b = v.board(.a);
            try b.drawMapAtPlace(a.title);
            try b.drawMapAtPlace(a.columns);
            try b.drawMapAtPlace(a.ranks);
            for (self.table, 0..) |e, k| try drawEntry(e, @intCast(first_row + 2 * k), v, a);
        }
        v.screen.colours = self.colours.shown;
    }

    /// An entry on `row`: its score (six digits, the first blank when it is 0), its round (two,
    /// the first blank when 0), its name, its level's name, in its player's colours if it is new.
    fn drawEntry(e: Score, row: i32, v: *view.View, a: *const Assets) !void {
        const look: render.Look = .{ .palette = if (e.new) |p| @as(u2, p) + 1 else 0 };
        var score: [6]u8 = undefined;
        _ = std.fmt.bufPrint(&score, "{d:0>6}", .{@min(e.score, 999_999)}) catch unreachable;
        if (score[0] == '0') score[0] = ' ';
        try v.write(.a, a.text, score_column, row, &score, look);
        var round: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&round, "{d:0>2}", .{@min(e.round, 99)}) catch unreachable;
        if (round[0] == '0') round[0] = ' ';
        try v.write(.a, a.text, round_column, row, &round, look);
        try v.write(.a, a.text, name_column, row, &e.name, look);
        var level: [level_cells]u8 = @splat(' ');
        const levels = a.options.levels;
        const name = if (e.level < levels.len) levels[e.level] else "";
        @memcpy(level[0..@min(name.len, level_cells)], name[0..@min(name.len, level_cells)]);
        try v.write(.a, a.text, level_column, row, &level, look);
    }
};

test "the table sorts by score, then level, then round, ties in their order" {
    var t = [_]Score{
        .{ .score = 10, .round = 1, .name = .{ 'A', 'A', 'A' } },
        .{ .score = 20, .round = 1 },
        .{ .score = 10, .round = 1, .level = 2 },
        .{ .score = 10, .round = 3, .name = .{ 'B', 'B', 'B' } },
    };
    HighScores.sort(&t);
    try std.testing.expectEqual(@as(u32, 20), t[0].score);
    try std.testing.expectEqual(@as(u8, 2), t[1].level);
    try std.testing.expectEqual(@as(u8, 3), t[2].round);
    try std.testing.expectEqual(@as(u8, 'A'), t[3].name[0]);
}
