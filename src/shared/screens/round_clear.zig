//! The round's clear (DESIGN.md S1; PLAN item 13), after a round won: its planes cleared and the
//! status bar kept, the colours fade in; "ROUND n CLEAR"; the bonuses' lines; then each bonus
//! counted into the scores of the players in play, 100 points a tick with its sound, its line in
//! the counted colours (the time's counts the timer down with it); a wait between the steps.
//! START held from the first count to the counting's end adds what is left at once. Then the
//! screen fades out and the next round follows, the game under way keeping the players' scores,
//! lives and special attacks (a stand-in when the content does not have that round).
//!
//! The bonuses (the original's): the clear's for the round and for each special attack the
//! players in play have left, the time's for each second the timer has left, the level's for
//! the options' LEVEL. What the picture shows is the tick before's, as in play.
//!
//! Its load (flow.zig) leaves the sound's driver running. Each of its frames writes the status
//! bar, the scores of the players in play, and what the tick asked for: a line or the header, the
//! digits of the bonus counted (transfers.zig, the sound's time).
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
const transfers = @import("transfers.zig");
const input = @import("../input.zig");
const world = @import("../world/root.zig");
const player_waiting = world.behaviours.player_waiting;
const Setup = setup_mod.Setup;

/// A step of the clear, each at least a tick: the waits last the record's ticks after their
/// first; a count, until its bonus is counted.
pub const Act = union(enum) {
    fade_in,
    header,
    wait,
    /// A bonus's line (by its place among the lines), in the normal colours, its digits when its
    /// bonus is not zero.
    line: u3,
    /// A bonus's line in the counted colours, with its digits.
    counted: u3,
    /// A bonus (by its place among the bonuses) counted into the scores.
    count: u3,
    /// A bonus's line again in the normal colours, its own zeros (a player's lives': its lives
    /// none, its name entered when its score enters the high scores).
    normal: u3,
    /// The players' names entered, each a tick of its entry; with none, a wait.
    names,
    fade_out,
    done,
};

/// A step of the program, and whether it is the counting's: START held on a counting step adds
/// the bonuses left at once and goes on from the first step after the counting (the original's
/// steps $14 to $51, then $52).
pub const Step = struct { act: Act, counting: bool = false, player: ?u1 = null };

fn step(act: Act) Step {
    return .{ .act = act };
}

fn counting(act: Act) Step {
    return .{ .act = act, .counting = true };
}

/// A step of player `k`'s lives, skipped when it is out of play.
fn lives(k: u1, act: Act) Step {
    return .{ .act = act, .player = k };
}

/// The steps of the rounds but the last.
pub const program = [_]Step{
    step(.fade_in),
    step(.header),
    step(.wait),
    step(.{ .line = 0 }),
    step(.{ .line = 1 }),
    step(.{ .line = 2 }),
    // The counting: each bonus's line in the counted colours, its count, its line back.
    counting(.wait),
    counting(.{ .counted = 0 }),
    counting(.{ .count = 0 }),
    counting(.wait),
    counting(.{ .normal = 0 }),
    counting(.{ .counted = 1 }),
    counting(.wait),
    counting(.{ .count = 1 }),
    counting(.wait),
    counting(.{ .normal = 1 }),
    counting(.{ .counted = 2 }),
    counting(.wait),
    counting(.{ .count = 2 }),
    counting(.wait),
    counting(.{ .normal = 2 }),
    step(.wait),
    step(.wait),
    step(.fade_out),
    step(.done),
};

/// The steps of the last round's clear: its players left's lines after the level's, each
/// player's lives counted into its score after the level's bonus (a player out of play skips its
/// line and its count); START does not skip its counting.
pub const last_program = [_]Step{
    step(.fade_in),
    step(.header),
    step(.wait),
    step(.{ .line = 0 }),
    step(.{ .line = 1 }),
    step(.{ .line = 2 }),
    step(.{ .line = 3 }),
    lives(0, .{ .line = 4 }),
    lives(1, .{ .line = 5 }),
    step(.wait),
    step(.{ .counted = 0 }),
    step(.{ .count = 0 }),
    step(.wait),
    step(.{ .normal = 0 }),
    step(.{ .counted = 1 }),
    step(.wait),
    step(.{ .count = 1 }),
    step(.wait),
    step(.{ .normal = 1 }),
    step(.{ .counted = 2 }),
    step(.wait),
    step(.{ .count = 2 }),
    step(.wait),
    step(.{ .normal = 2 }),
    lives(0, .{ .counted = 4 }),
    lives(0, .wait),
    lives(0, .{ .count = 3 }),
    lives(0, .{ .normal = 4 }),
    lives(1, .{ .counted = 5 }),
    lives(1, .wait),
    lives(1, .{ .count = 4 }),
    lives(1, .{ .normal = 5 }),
    step(.names),
    step(.wait),
    step(.fade_out),
    step(.done),
};

/// The bonus a line shows the digits of (the players left's header shows none).
fn bonusOf(line: u3) ?u3 {
    return switch (line) {
        0, 1, 2 => line,
        3 => null,
        else => line - 1,
    };
}

/// The player whose lives a line or a bonus is (player 1's, player 2's), when it is one.
fn livesOf(line: u3) ?u1 {
    return switch (line) {
        4 => 0,
        5 => 1,
        else => null,
    };
}

/// The first step after the counting, where START held goes. The counting's steps are one run.
const skip_to = blk: {
    var first: ?usize = null;
    var after: ?usize = null;
    for (program, 0..) |s, i| {
        if (s.counting and first == null) first = i;
        if (s.counting and after != null) @compileError("the counting's steps are not one run");
        if (!s.counting and first != null and after == null) after = i;
    }
    break :blk after orelse @compileError("no step after the counting");
};

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
    lines: [6]Line = @splat(.{}),
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
    /// The last round's (its lives counted); the players out of play.
    last: bool = false,
    out: [2]bool = .{ false, false },
    /// The last round's name entries: a player's whose score enters the high scores, running
    /// (as a waiting player's), and entered; the pads of the last tick.
    names: [2]?player_waiting.Mind = .{ null, null },
    named: [2]bool = .{ false, false },
    last_pads: [2]input.Pad = .{ .{}, .{} },
    /// The bonuses left to count: the clear's, the time's, the level's, each player's lives'.
    bonuses: [5]u32 = .{ 0, 0, 0, 0, 0 },
    /// The line a count draws its bonus's digits on at each tick.
    counting: ?u3 = null,
    now: Shown = .{},
    shown: Shown = .{},
    colours: Colours = .{},
    /// What the tick asks its frame to write besides the status bar and the scores: a line's or
    /// the header's rows and cells, the counted bonus's digits.
    writes: Writes = .{},

    pub const Writes = struct { rows: u8 = 0, cells: u16 = 0 };

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
        /// The rounds the content has, the next among them or not.
        rounds: library.Rounds,
        /// The kinds of entity (the waiting player's name entry's blink), the high scores at
        /// power-on.
        kinds: *const world.Kinds,
        first_scores: *const records.HighScores,
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
            .rounds = "rounds",
            .kinds = "entities",
            .first_scores = "screens/high_scores",
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
        self.writes = .{};
        defer turn.frame = self.frameOf(&turn.setup.progress, a);
        // The set-up's tick goes on to the first step (the original's set-up ends with the
        // clear's first tick).
        if (!self.set_up) {
            turn.releasePads();
            self.setUp(turn, a);
        }
        const c = &a.screen.clear;
        const g = &turn.setup.progress;
        const program_steps = self.steps();
        if (program_steps[self.act].counting and startHeld(turn, g)) self.skip(g, c, a.screen.status_bar.score_most);
        switch (program_steps[self.act].act) {
            .fade_in, .fade_out => if (self.colours.stepFade()) self.next(),
            .header => {
                self.now.header = true;
                // Counts of the frame's writes: a header map past the screen's (an edited one)
                // counts as the most they hold, not a crash.
                self.writes = .{ .rows = std.math.lossyCast(u8, a.header.height), .cells = std.math.lossyCast(u16, @as(u32, a.header.width) * a.header.height) };
                self.next();
            },
            .wait => self.wait(c),
            .line => |k| {
                const b = bonusOf(k);
                self.now.lines[k] = .{ .shown = true, .digits = if (b) |n| if (self.bonuses[n] != 0) self.bonuses[n] else null else null };
                self.writes = lineWrites(c, k);
                self.next();
            },
            .counted => |k| {
                self.now.lines[k] = .{ .shown = true, .counted = true, .digits = self.bonuses[bonusOf(k).?] };
                self.writes = lineWrites(c, k);
                self.next();
            },
            .normal => |k| {
                self.now.lines[k] = .{ .shown = true };
                self.writes = lineWrites(c, k);
                // A player's lives counted: its name is entered when its score enters the high
                // scores.
                if (livesOf(k)) |pk| if (self.enters(turn.setup, a, g.players[pk].score)) {
                    self.names[pk] = .{};
                    player_waiting.beginName(&self.names[pk].?, blinkOf(a));
                };
                self.next();
            },
            .names => if (self.entering()) {
                self.enterNames(turn, a);
                if (!self.entering()) self.next();
            } else self.wait(c),
            .count => |b| {
                // Its line: the bonus's, by its place.
                const k: u3 = if (b < 3) b else b + 1;
                if (b == 1 and g.timer != 0) {
                    g.timer -= 1;
                    turn.play(a.tick);
                }
                if (self.bonuses[b] == 0) {
                    self.counting = null;
                    // A player's lives counted, its status bar shows none.
                    if (livesOf(k)) |pk| g.players[pk].lives = 0;
                    self.next();
                } else {
                    const n = @min(c.count, self.bonuses[b]);
                    self.bonuses[b] -= n;
                    self.counting = k;
                    // A player's lives go to its score; the others to every player in play's.
                    for (&g.players, 0..) |*p, pk| {
                        if (!p.in_play) continue;
                        if (livesOf(k)) |only| if (only != pk) continue;
                        addScore(p, n, a.screen.status_bar.score_most);
                    }
                    turn.play(a.tick);
                    self.now.lines[k].digits = self.bonuses[b];
                    self.writes.cells += digitsOf(c, k);
                }
            },
            .done => {
                // After the last round, the ending (in the boss's chair when a player kept the
                // offer's yes).
                if (self.last) return if (g.boss_ending) .boss_ending else .ending;
                g.round += 1;
                return if (a.rounds.of(g.round) != null) .done else .missing;
            },
        }
        self.now.bar = barOf(g);
        // A name entry shows on its player's part of the status bar.
        for (self.names, 0..) |m_, k| {
            const m = m_ orelse continue;
            var x: round_screen.PlayerBar.Naming = .{ .score = g.players[k].score, .places = undefined };
            for (&x.places, 0..) |*q, place| q.* = player_waiting.shownAt(&m, place);
            self.now.bar.players[k] = .{ .naming = x };
        }
        return null;
    }

    fn wait(self: *RoundClear, c: *const records.Clear) void {
        if (!self.waiting) {
            self.waiting = true;
            self.left = c.wait;
            return;
        }
        self.left -|= 1;
        if (self.left != 0) return;
        self.waiting = false;
        self.next();
    }

    /// Whether `score` enters the high-score table (beats its last entry).
    fn enters(_: *const RoundClear, setup: *const Setup, a: *const Assets, score: u32) bool {
        const table = setup.high_scores orelse HighScores.firstTable(a.first_scores);
        const last = table[table.len - 1];
        const ranked: world.script.Ranked = .{ .score = last.score, .level = last.level, .round = last.round };
        return ranked.beatenBy(score);
    }

    /// A name entry runs.
    fn entering(self: *const RoundClear) bool {
        for (self.names, self.named) |m, done| if (m != null and !done) return true;
        return false;
    }

    /// A tick of each name entry running, on its player's pad (the presses since the last
    /// tick); a name entered goes into the high-score table.
    fn enterNames(self: *RoundClear, turn: *scene.Turn, a: *const Assets) void {
        const setup = turn.setup;
        const g = &setup.progress;
        const buttons = a.screen.buttons.of(setup.control);
        const letters: u8 = @intCast(a.screen.name_entry.letters.len);
        const blink = blinkOf(a);
        for (&self.names, &self.named, 0..) |*m_, *done, k| {
            const pad = if (k == 0) turn.pads.pad1 else turn.pads.pad2;
            defer self.last_pads[k] = pad;
            const m = &(m_.* orelse continue);
            if (done.*) continue;
            const c = world.systems.commandOf(self.last_pads[k], pad, buttons);
            if (!player_waiting.enterName(m, letters, blink, c)) continue;
            done.* = true;
            var table = setup.high_scores orelse HighScores.firstTable(a.first_scores);
            round_screen.rankIn(&table, @intCast(k), .{
                .score = g.players[k].score,
                .round = g.round,
                .name = round_screen.nameOf(a.screen.name_entry.letters, m.name),
                .level = setup.level,
            });
            setup.high_scores = table;
        }
    }

    fn steps(self: *const RoundClear) []const Step {
        return if (self.last) &last_program else &program;
    }

    /// The next step: a player out of play's lives' steps are passed at once.
    fn next(self: *RoundClear) void {
        const all = self.steps();
        self.act += 1;
        while (all[self.act].player) |k| {
            if (!self.out[k]) break;
            self.act += 1;
        }
        if (all[self.act].act == .fade_out) self.colours.startFade(.black);
    }

    /// The frame that shows the tick: the colours when the tick touched them, the status bar's
    /// rows, the partial cells of the round's bosses' bars, the scores of the players in play,
    /// cell by cell, and what the tick wrote.
    fn frameOf(self: *const RoundClear, g: *const setup_mod.Progress, a: *const Assets) transfers.Frame {
        const sb = &a.screen.status_bar;
        var players: u16 = 0;
        for (g.players) |p| players += @intFromBool(p.in_play);
        return .{
            .colours = self.colours.copy,
            .status_rows = sb.image_rows,
            .status_cells = sb.image_cells,
            .bar_parts = g.boss_bars,
            .cell_rows = self.writes.rows,
            .cells = players * round_screen.digitsOf(sb.score_most) + self.writes.cells,
        };
    }

    /// START held on the pad of a player in play.
    fn startHeld(turn: *const scene.Turn, g: *const setup_mod.Progress) bool {
        if (g.players[0].in_play and turn.pads.pad1.start) return true;
        if (g.players[1].in_play and turn.pads.pad2.start) return true;
        return false;
    }

    /// START held: what is left of the bonuses goes to the scores at once (held at `most`), the
    /// lines are drawn again with their own zeros (the original's from the ROM), and the
    /// counting ends.
    fn skip(self: *RoundClear, g: *setup_mod.Progress, c: *const records.Clear, most: u32) void {
        var left: u32 = 0;
        for (self.bonuses) |b| left += b;
        for (&g.players) |*p| if (p.in_play) addScore(p, left, most);
        for (self.now.lines[0..3], 0..) |*l, k| {
            l.* = .{ .shown = true };
            // Their letters written cell by cell.
            self.writes.cells += @intCast(c.lines[k].text.len);
        }
        // The timer shows 00 from then on: the original draws it from the other byte of the
        // timer's count, which a round's timer leaves at 0.
        g.timer = 0;
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
        self.last = g.round == c.last_round;
        self.out = .{ !g.players[0].in_play, !g.players[1].in_play };
        // The last round's lives: each player's, a bonus a life by LEVEL (none for a player on
        // its last life: the original's count of a life less than none, 65536 of them, is not
        // taken).
        const life = a.screen.levels.life_bonus[@min(turn.setup.level, 3)];
        self.bonuses = .{
            c.clear_bonus * (1 + specials),
            c.time_bonus * g.timer,
            c.level_bonus * turn.setup.level,
            if (self.last and g.players[0].in_play) life * g.players[0].lives else 0,
            if (self.last and g.players[1].in_play) life * g.players[1].lives else 0,
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

/// The ticks of a name entry's blink: the waiting player's.
fn blinkOf(a: *const RoundClear.Assets) u8 {
    const k = a.kinds.find(player_waiting_kind) orelse return 1;
    return @intCast(a.kinds.get(k).definition.number("name_blink") orelse 1);
}

const player_waiting_kind = "player_waiting";
const HighScores = @import("high_scores.zig").HighScores;

/// A bonus's line: its text in its colours, its digits over the text's zeros.
fn drawLine(v: *view.View, a: *const RoundClear.Assets, k: usize, l: Line) !void {
    const c = &a.screen.clear;
    const line = c.lines[k];
    const look: render.Look = .{ .palette = if (l.counted) c.counted else c.normal };
    try v.write(.a, a.text, line.at.x, line.at.y, line.text, look);
    if (l.digits) |d| {
        var buf: [10]u8 = undefined;
        try v.write(.a, a.text, line.at.x + c.digits, line.at.y, round_screen.digits(&buf, d, digitsOf(c, k)), look);
    }
}

/// A bonus's digits: as many as its line's zeros there.
fn digitsOf(c: *const records.Clear, k: usize) u8 {
    const text = c.lines[k].text;
    var width: u8 = 0;
    while (c.digits + width < text.len and text[c.digits + width] == '0') width += 1;
    return width;
}

/// A bonus's line written: a row of its letters.
fn lineWrites(c: *const records.Clear, k: usize) RoundClear.Writes {
    return .{ .rows = 1, .cells = @intCast(c.lines[k].text.len) };
}

/// `points` to a player's score, which holds at `most` (play's record's `score_most`).
fn addScore(p: *setup_mod.Gamer, points: u32, most: u32) void {
    p.score = @min(p.score +| points, most);
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

test "the steps: the counting from the wait after the lines, a skip to the wait after it" {
    try std.testing.expect(program[0].act == .fade_in and program[program.len - 1].act == .done);
    // The original's skip starts at the wait after the level's line ($14), and goes to the wait
    // after the level's line back in the normal colours ($52).
    try std.testing.expect(program[5].act == .line and program[6].counting and program[6].act == .wait);
    try std.testing.expect(program[skip_to - 1].act == .normal and program[skip_to].act == .wait);
}

test "START held at the counting's first wait: the bonuses at once, held at the most, the lines' zeros" {
    var r: RoundClear = .{ .act = 6, .bonuses = .{ 20000, 4500, 10000, 0, 0 } };
    r.now.lines[0] = .{ .shown = true, .digits = 20000 };
    var g: setup_mod.Progress = .{ .round = 1, .timer = 45 };
    g.players[0] = .{ .in_play = true, .score = 995_000 };
    g.players[1] = .{ .in_play = false, .score = 100 };
    const line: records.ClearLine = .{ .text = "CLEAR BONUS  000000 PTS", .at = .{ .x = 8, .y = 12 } };
    const c: records.Clear = .{ .header = "", .header_at = .{ .x = 7, .y = 7 }, .number = .{ .x = 13, .y = 0 }, .lines = @splat(line), .digits = 13, .normal = 1, .counted = 2, .wait = 32, .clear_bonus = 10000, .time_bonus = 100, .level_bonus = 10000, .count = 100, .colours = "" };
    r.skip(&g, &c, 999_900);
    // The lines written again, letter by letter.
    try std.testing.expectEqual(@as(u16, 3 * 23), r.writes.cells);
    try std.testing.expectEqual(@as(u32, 999_900), g.players[0].score);
    try std.testing.expectEqual(@as(u32, 100), g.players[1].score);
    try std.testing.expectEqual(@as(u8, skip_to), r.act);
    try std.testing.expectEqual(@as(u8, 0), g.timer);
    for (r.now.lines[0..3]) |l| try std.testing.expect(l.shown and !l.counted and l.digits == null);
}
