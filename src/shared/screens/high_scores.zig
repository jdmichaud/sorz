//! The high scores, after the attract demo, a game over and the good ending: THE BEST 10 PLAYERS,
//! the table sorted and drawn at once (a new entry in its player's colours, once), the name entry
//! music, then 600 ticks or START on either pad, and the Sega logo again. No fade: the screen
//! cuts from dark to the table and from the table to dark.
//!
//! Players 3 and 4's new entries (the port's, DESIGN.md 10.7 E4) take colours of the port's own,
//! as bright as the cartridge's two, on the palette line its table leaves free (`party`): player
//! 3's green in the font's colour, player 4's blue in another, the font's letters drawn in it
//! (`recoloured`); their shadows black as players 1 and 2's. The table shows those colours only
//! when it has such an entry.
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

/// Players 3 and 4's colours: the palette line the cartridge's table leaves free, the font's
/// colour (1) player 3's green, another (3) player 4's blue, the shadow (2) black.
pub const party = struct {
    pub const line: u2 = 3;
    const font_colour = 1;
    const shadow = 2;
    pub const fourth = 3;
    pub const colours: art.Palette = .{
        .name = "high scores, players 3 and 4",
        .provenance = "the port's own (DESIGN.md 10.7, E4)",
        .colours = blk: {
            var c: [art.palette_count][art.palette_size]?art.Colour = @splat(@splat(null));
            c[line][font_colour] = .{ .r = 1, .g = 6, .b = 2 };
            c[line][shadow] = .black;
            c[line][fourth] = .{ .r = 2, .g = 4, .b = 7 };
            break :blk c;
        },
    };
};

/// The tiles of `sheet` with the font's colour turned to player 4's (`party.fourth`), into
/// `into` (as many as the sheet has; more are blank).
pub fn recoloured(sheet: []const art.Tile, into: []art.Tile) void {
    for (into, 0..) |*t, i| {
        t.* = if (i < sheet.len) sheet[i] else @splat(0);
        for (t) |*px| {
            if (px.* == party.font_colour) px.* = party.fourth;
        }
    }
}

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
        defer if (self.ticks != 2) {
            turn.frame = .{ .colours = self.colours.copy, .play = true };
        };
        if (self.ticks == 1) {
            turn.releasePads();
            self.colours.show(a.colours);
            var table = turn.setup.high_scores orelse firstTable(a.first);
            sort(&table);
            self.table = table;
            // Players 3 and 4's colours, when an entry is theirs.
            for (self.table) |e| if (e.new) |k| if (k >= 2) {
                self.colours.show(&party.colours);
                break;
            };
            // The new entries are coloured once.
            for (&table) |*e| e.new = null;
            turn.setup.high_scores = table;
            turn.play(a.music);
            self.left = shown_ticks;
            return null;
        }
        // The set-up's last frame shows the table, but the original still holds its sound's
        // driver and the frame's work.
        if (self.ticks == 2) {
            turn.sound_driver = false;
            turn.frame = null;
        }
        self.left -= 1;
        if (self.left == 0) return .done;
        if (turn.pressed.pad1.start or turn.pressed.pad2.start) return .start;
        return null;
    }

    /// The content's table, as the game keeps it.
    pub fn firstTable(first: *const records.HighScores) [setup_mod.high_scores]Score {
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

    pub fn beats(a: Score, b: Score) bool {
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
            // Player 4's letters, the font's in its colour.
            var fourth: ?library.Text = null;
            var fourth_sheet: art.TileSheet = undefined;
            for (self.table) |e| if (e.new == 3) {
                const sheet = a.text.sheet;
                const tiles = try v.tileBlock(sheet.tiles.len);
                recoloured(sheet.tiles, tiles);
                fourth_sheet = .{ .name = sheet.name, .file = sheet.file, .tiles = tiles };
                fourth = .{ .font = a.text.font, .sheet = &fourth_sheet };
                break;
            };
            for (self.table, 0..) |e, k| try drawEntry(e, @intCast(first_row + 2 * k), v, a, fourth);
        }
        v.screen.colours = self.colours.shown;
    }

    /// An entry on `row`: its score (six digits, the first blank when it is 0), its round (two,
    /// the first blank when 0), its name, its level's name, in its player's colours if it is new
    /// (players 1 and 2's lines; players 3 and 4's the port's, player 4's letters `fourth`).
    fn drawEntry(e: Score, row: i32, v: *view.View, a: *const Assets, fourth: ?library.Text) !void {
        const look: render.Look = .{ .palette = if (e.new) |p| if (p < 2) @as(u2, p) + 1 else party.line else 0 };
        const text = if (e.new == 3) fourth orelse a.text else a.text;
        var score: [6]u8 = undefined;
        _ = std.fmt.bufPrint(&score, "{d:0>6}", .{@min(e.score, 999_999)}) catch unreachable;
        if (score[0] == '0') score[0] = ' ';
        try v.write(.a, text, score_column, row, &score, look);
        var round: [2]u8 = undefined;
        _ = std.fmt.bufPrint(&round, "{d:0>2}", .{@min(e.round, 99)}) catch unreachable;
        if (round[0] == '0') round[0] = ' ';
        try v.write(.a, text, round_column, row, &round, look);
        try v.write(.a, text, name_column, row, &e.name, look);
        var level: [level_cells]u8 = @splat(' ');
        const levels = a.options.levels;
        const name = if (e.level < levels.len) levels[e.level] else "";
        @memcpy(level[0..@min(name.len, level_cells)], name[0..@min(name.len, level_cells)]);
        try v.write(.a, text, level_column, row, &level, look);
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

test "players 3 and 4's colours: a free line, the font's colour player 3's, another player 4's" {
    const c = party.colours.colours;
    // The cartridge's table gives lines 0 to 2; line 3 is the port's.
    for (c[0..party.line]) |l| for (l) |x| try std.testing.expect(x == null);
    const third = c[party.line][1].?;
    const fourth = c[party.line][party.fourth].?;
    try std.testing.expect(!third.eql(fourth) and c[party.line][2].?.eql(.black));
    // Player 4's letters: the font's colour turned, the shadow and the ground kept.
    var font: [2]art.Tile = .{ @splat(1), @splat(0) };
    font[0][0] = 2;
    font[1][5] = 1;
    var out: [3]art.Tile = undefined;
    recoloured(&font, &out);
    try std.testing.expectEqual(@as(u8, 2), out[0][0]);
    try std.testing.expectEqual(@as(u8, party.fourth), out[0][1]);
    try std.testing.expectEqual(@as(u8, 0), out[1][0]);
    try std.testing.expectEqual(@as(u8, party.fourth), out[1][5]);
    try std.testing.expectEqual(@as(art.Tile, @splat(0)), out[2]);
}
