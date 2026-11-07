//! The status bar of a game of three or four players (DESIGN.md 10.7, E4; PLAN item 48), the
//! port's own: four slots in one row across the bar, the round's timer between the second and
//! the third. A slot's first row is its player's name and a dash, the police special's icon (a
//! cell of the port's own art, `police_icon`: the cartridge's is two rows high) and its count;
//! the second, the health bar (the cartridge's cells, at the slot's width, scaled) and the lives.
//! No score shows (it still counts, for the high scores); the bosses' bars stay below the bar. A
//! slot whose player is not in the game is the bar's own cells.
//!
//! A player out of lives enters its name on its slot and answers the continue's question there,
//! with its own pad (world/behaviours/player_waiting.zig), and out of the game its slot shows the
//! game over; the slot's two rows of eight cells lay out the cartridge's texts (PLAN item 53),
//! in its font, its cursor blinking as the cartridge's does:
//!
//!     CONTINUE        052300    1P- GAME
//!     ->YES x3      NAME ABC        OVER
//!
//! - the question: the cartridge's (CONTINUE), then the answer under the cursor, YES or NO (up
//!   or down turns it, as up or down moves the cartridge's cursor between its two rows), and the
//!   continues left as the slot counts its lives (x and a digit, the lives' cells);
//! - the name entry: the score that enters the high-score table (the bar's six digits, as the
//!   cartridge's bar shows it), then the label and the name's three places (the letter at the
//!   cursor blinking; the end mark shows there when it is chosen);
//! - out of the game: the player's name as it plays, and GAME OVER, blinking.
const std = @import("std");
const art = @import("../content/art.zig");
const records = @import("../content/screens.zig");
const render = @import("../render/root.zig");
const setup_mod = @import("../setup.zig");
const world = @import("../world/root.zig");
const round = @import("round.zig");

const Cell = records.Cell;
const Answer = world.behaviours.player_waiting.Answer;

pub const slots = setup_mod.max_players;

/// A slot's name: three letters of the game's font, spaces after a shorter one.
pub const Name = [3]u8;

/// A slot's cells across, and the cells between two slots, and between a slot and the timer
/// (two big digits across).
pub const width = 8;
pub const gap = 1;
const timer_cells = 2;

/// From a slot's first cell: the police icon, the marks (`x`) and the counts (the special
/// attacks', the lives'), one column each on both rows; the health bar's cells before them.
pub const icon_at = 5;
pub const mark_at = 6;
pub const count_at = 7;
pub const health_cells = 6;

/// The continue's answers on a slot: the port's words (the cartridge's rows, CONTINUE and GAME
/// OVER, do not fit with the cursor and the count).
pub const yes = "YES";
pub const no = "NO";

/// From a slot's first cell: the answer after the cursor; the game over's words.
const answer_at = 1;
const out_at = 4;

/// The places of a name.
const places = world.behaviours.player_waiting.places;

/// The places of a slot's parts on the fixed layer.
pub const Places = struct {
    /// The slot's first cell on each of its rows.
    rows: [2]Cell,
    name: Cell,
    icon: Cell,
    specials_mark: Cell,
    specials: Cell,
    health: Cell,
    lives_mark: Cell,
    lives: Cell,
};

/// Slot `k`'s places, by the timer's first cell (`time`) and the bar's rows (`rows`: the
/// cartridge's names' and health bars'): two slots before the timer, two after, a cell apart.
pub fn placesOf(time: Cell, rows: [2]u8, k: usize) Places {
    const pitch = width + gap;
    const x: u8 = if (k < 2)
        time.x - @as(u8, @intCast((2 - k) * pitch))
    else
        time.x + timer_cells + gap + @as(u8, @intCast((k - 2) * pitch));
    return .{
        .rows = .{ .{ .x = x, .y = rows[0] }, .{ .x = x, .y = rows[1] } },
        .name = .{ .x = x, .y = rows[0] },
        .icon = .{ .x = x + icon_at, .y = rows[0] },
        .specials_mark = .{ .x = x + mark_at, .y = rows[0] },
        .specials = .{ .x = x + count_at, .y = rows[0] },
        .health = .{ .x = x, .y = rows[1] },
        .lives_mark = .{ .x = x + mark_at, .y = rows[1] },
        .lives = .{ .x = x + count_at, .y = rows[1] },
    };
}

/// Player `k`'s name on its slot: its name in network play (the setup's), else CPU for a CPU,
/// else 1P to 4P.
pub fn nameOf(setup: *const setup_mod.Setup, k: usize) Name {
    if (setup.names[k]) |n| return n;
    if (setup.cpu[k]) return "CPU".*;
    return .{ '1' + @as(u8, @intCast(k)), 'P', ' ' };
}

/// The names of a game's slots.
pub fn namesOf(setup: *const setup_mod.Setup) [slots]Name {
    var out: [slots]Name = undefined;
    for (&out, 0..) |*n, k| n.* = nameOf(setup, k);
    return out;
}

/// Whether the game's status bar is the party's: three players or four.
pub fn shows(setup: *const setup_mod.Setup) bool {
    return setup.players.count() > 2;
}

/// What a slot shows of its player (`round.PlayerBar`, the score only while it enters its name).
pub const Slot = union(enum) {
    none,
    playing: struct { lives: u8, specials: u8, health: u8 },
    /// The continues left, the answer the cursor is on, whether the cursor shows (it blinks).
    asking: struct { continues: u8, answer: Answer, cursor: bool },
    naming: round.PlayerBar.Naming,
    /// Out of the game: whether its name shows (not at the tick its slot is cleared), and the game
    /// over's words (they blink).
    out: struct { name: bool, game_over: bool },

    pub fn of(p: round.PlayerBar) Slot {
        return switch (p) {
            .none => .none,
            .playing => |x| .{ .playing = .{ .lives = x.lives, .specials = x.specials, .health = x.health } },
            .asking => |x| .{ .asking = .{ .continues = x.continues, .answer = x.answer, .cursor = x.cursor != null } },
            .naming => |x| .{ .naming = x },
            .out => |x| .{ .out = .{ .name = x.name, .game_over = x.game_over } },
        };
    }
};

/// The health bar's pixels of a slot: `health` points of the cartridge's bar (`most`: its
/// pixels, a point each) scaled to the slot's cells, up (a fighter with health shows some).
pub fn healthPixels(health: u8, most: u16) u16 {
    const shown: u32 = health_cells * art.tile_side;
    if (most == 0) return 0;
    return @intCast(@min((@as(u32, health) * shown + most - 1) / most, shown));
}

/// The slots that changed since `was` (all of them when null: the bar's rows are first its own
/// cells again, the cartridge's parts gone).
pub fn draw(board: *render.Board, a: anytype, now: round.Bar, was: ?round.Bar) !void {
    const names = now.party orelse return;
    const sb = &a.screen.status_bar;
    const rows: [2]u8 = .{ sb.players[0].name_at.y, sb.players[0].health.y };
    if (was == null) for (rows) |y| {
        round.restore(board, a, .{ .x = 0, .y = y }, @intCast(a.status_bar.width));
    };
    for (0..slots) |k| {
        const at = placesOf(sb.time, rows, k);
        const slot: Slot = .of(now.players[k]);
        const before: ?Slot = if (was) |w| .of(w.players[k]) else null;
        const renamed = if (was) |w| if (w.party) |n| !std.mem.eql(u8, &n[k], &names[k]) else true else true;
        // A name changed (the CPU's player taken, a shorter name): the slot is drawn whole again.
        if (renamed and was != null) clear(board, a, at);
        try drawSlot(board, a, k, at, names[k], slot, if (renamed) null else before);
    }
}

/// Slot `k` at `at`: the parts that changed since `was` (all when null). A slot that changes
/// what it shows (playing, asking...) is cleared, then drawn whole; one that is not playing is
/// drawn whole at each change.
fn drawSlot(board: *render.Board, a: anytype, k: usize, at: Places, name: Name, now: Slot, was: ?Slot) !void {
    if (was) |w| if (std.meta.eql(w, now)) return;
    const kept: ?@FieldType(Slot, "playing") = if (was) |w| switch (w) {
        .playing => |x| if (now == .playing) x else null,
        else => null,
    } else null;
    if (kept == null and was != null) clear(board, a, at);
    const text = a.text;
    switch (now) {
        .none => {},
        .playing => |x| {
            if (kept == null) {
                try writeName(board, a, at.name, name);
                const c = a.police_icon.cell(0, 0);
                try board.put(at.icon.x, at.icon.y, &police_icon, .{ .palette = c.palette, .priority = c.priority });
                try board.write(text.sheet, text.font, at.specials_mark.x, at.specials_mark.y, "x", .{});
                try board.write(text.sheet, text.font, at.lives_mark.x, at.lives_mark.y, "x", .{});
            }
            if (kept == null or kept.?.specials != x.specials) try digit(board, a, at.specials, x.specials);
            if (kept == null or kept.?.lives != x.lives) try digit(board, a, at.lives, x.lives);
            if (kept == null or kept.?.health != x.health) try healthBar(board, a, if (k % 2 == 0) a.health_1 else a.health_2, at.health, x.health);
        },
        .asking => |x| {
            const cq = &a.screen.continue_question;
            try writeCut(board, a, at.rows[0], width, cq.question);
            if (x.cursor) try board.write(text.sheet, text.font, at.rows[1].x, at.rows[1].y, cq.cursor, .{});
            try board.write(text.sheet, text.font, at.rows[1].x + answer_at, at.rows[1].y, if (x.answer == .yes) yes else no, .{});
            try board.write(text.sheet, text.font, at.lives_mark.x, at.lives_mark.y, "x", .{});
            try digit(board, a, at.lives, x.continues);
        },
        .naming => |x| {
            const ne = &a.screen.name_entry;
            var buf: [10]u8 = undefined;
            const most = round.digitsOf(a.screen.status_bar.score_most);
            const score = round.digits(&buf, x.score, @min(most, width));
            try board.write(text.sheet, text.font, at.rows[0].x + width - @as(u8, @intCast(score.len)), at.rows[0].y, score, .{});
            try writeCut(board, a, at.rows[1], width - places - 1, ne.label);
            const first = at.rows[1].x + width - places;
            for (x.places, 0..) |letter, q| {
                const l = letter orelse continue;
                if (l < ne.letters.len) try board.write(text.sheet, text.font, first + @as(u8, @intCast(q)), at.rows[1].y, ne.letters[l], .{});
            }
        },
        // Its name, and the game over's words a row each, after it.
        .out => |x| {
            if (x.name) try writeName(board, a, at.name, name);
            if (x.game_over) {
                var words = std.mem.tokenizeScalar(u8, a.screen.continue_question.game_over, ' ');
                for (at.rows) |row| try writeCut(board, a, .{ .x = row.x + out_at, .y = row.y }, width - out_at, words.next() orelse break);
            }
        },
    }
}

/// `text` from `at`, its first `cells` glyphs at most (a glyph a cell).
fn writeCut(board: *render.Board, a: anytype, at: Cell, cells: u8, text: []const u8) !void {
    const font = a.text.font;
    var rest = text;
    var x = at.x;
    while (rest.len != 0 and x < at.x + cells) : (x += 1) {
        const g = font.glyphAt(rest) orelse return error.NoGlyph;
        try board.write(a.text.sheet, font, x, at.y, rest[0..g.len], .{});
        rest = rest[g.len..];
    }
}

/// A slot's cells, back to the bar's own.
fn clear(board: *render.Board, a: anytype, at: Places) void {
    for (at.rows) |row| round.restore(board, a, row, width);
}

/// A name and its dash, its letters the font's (one it lacks leaves its cell).
fn writeName(board: *render.Board, a: anytype, at: Cell, name: Name) !void {
    const letters = std.mem.trimEnd(u8, &name, " ");
    for (0..letters.len) |i| board.write(a.text.sheet, a.text.font, at.x + @as(u8, @intCast(i)), at.y, letters[i .. i + 1], .{}) catch |e| switch (e) {
        error.NoGlyph => {},
        else => return e,
    };
    try board.write(a.text.sheet, a.text.font, at.x + @as(u8, @intCast(letters.len)), at.y, "-", .{});
}

/// A count: a digit of the font; 10 or more shows 9.
fn digit(board: *render.Board, a: anytype, at: Cell, n: u8) !void {
    const d = [1]u8{'0' + @as(u8, @min(n, 9))};
    try board.write(a.text.sheet, a.text.font, at.x, at.y, &d, .{});
}

/// A slot's health bar of `health` points: the cartridge's bar's cells (`map`: its full cells,
/// the partial one, its empty cells), its pixels scaled to the slot's cells (`healthPixels`),
/// the partial cell's fill `play/fills`' by the pixels left.
fn healthBar(board: *render.Board, a: anytype, map: *const art.TileMap, at: Cell, health: u8) !void {
    const cells = (map.width - 1) / 2;
    const pixels = healthPixels(health, cells * art.tile_side);
    const full = pixels / art.tile_side;
    for (0..health_cells) |i| {
        const x = at.x + @as(u8, @intCast(i));
        if (i < full) {
            try round.putCell(board, map, 0, 0, x, at.y);
        } else if (i == full) {
            const c = map.cell(cells, 0);
            try board.put(x, at.y, &a.fills.tiles[pixels % art.tile_side], .{ .palette = c.palette, .priority = c.priority });
        } else try round.putCell(board, map, cells + 1, 0, x, at.y);
    }
}

/// The police special's icon on one cell, the port's own art in the cartridge's colours (those
/// of `play/police_icon`'s palette, the bar's): the cartridge's sign, a dark S on a yellow
/// square, its burst's orange and red around it. 2 is the bar's ground, D the S's grey edge.
pub const police_icon: art.Tile = tile: {
    const rows = [8]*const [8]u8{
        "2F6FF6F2",
        "FEEEEEEF",
        "6ED222E6",
        "FE2EEEEF",
        "FEED2EEF",
        "FEEEE2EF",
        "6ED22EE6",
        "2F6FF6F2",
    };
    var t: art.Tile = undefined;
    for (rows, 0..) |row, y| for (row, 0..) |ch, x| {
        t[y * 8 + x] = switch (ch) {
            '2' => 2,
            '6' => 6,
            'D' => 13,
            'E' => 14,
            'F' => 15,
            else => unreachable,
        };
    };
    break :tile t;
};

// --- tests --------------------------------------------------------------------------------------

const testing = std.testing;

test "the four slots: two before the timer, two after, a cell apart, inside the bar" {
    const time: Cell = .{ .x = 19, .y = 1 };
    const rows: [2]u8 = .{ 1, 2 };
    const firsts = [slots]u8{ 1, 10, 22, 31 };
    for (firsts, 0..) |x, k| {
        const at = placesOf(time, rows, k);
        try testing.expectEqual(x, at.name.x);
        try testing.expectEqual(@as(u8, 1), at.name.y);
        try testing.expectEqual(Cell{ .x = x + 5, .y = 1 }, at.icon);
        try testing.expectEqual(Cell{ .x = x + 6, .y = 1 }, at.specials_mark);
        try testing.expectEqual(Cell{ .x = x + 7, .y = 1 }, at.specials);
        try testing.expectEqual(Cell{ .x = x, .y = 2 }, at.health);
        try testing.expectEqual(Cell{ .x = x + 6, .y = 2 }, at.lives_mark);
        try testing.expectEqual(Cell{ .x = x + 7, .y = 2 }, at.lives);
    }
    // The second's last cell a cell before the timer, the third's first a cell after it; the
    // fourth's last before the bar's right edge (its 40th cell).
    try testing.expectEqual(@as(u8, time.x - 2), placesOf(time, rows, 1).name.x + width - 1);
    try testing.expectEqual(@as(u8, time.x + 3), placesOf(time, rows, 2).name.x);
    try testing.expectEqual(@as(u8, 38), placesOf(time, rows, 3).name.x + width - 1);
}

test "a slot's name: the network's, CPU, else 1P to 4P" {
    var setup: setup_mod.Setup = .{ .players = .four };
    setup.cpu[3] = true;
    setup.names[1] = "BOB".*;
    const names = namesOf(&setup);
    try testing.expectEqualStrings("1P ", &names[0]);
    try testing.expectEqualStrings("BOB", &names[1]);
    try testing.expectEqualStrings("3P ", &names[2]);
    try testing.expectEqualStrings("CPU", &names[3]);
    try testing.expect(shows(&setup));
    try testing.expect(!shows(&.{ .players = .two }));
    try testing.expect(shows(&.{ .players = .three }));
}

test "a slot's health bar: the cartridge's 80 pixels scaled to six cells, up" {
    try testing.expectEqual(@as(u16, 48), healthPixels(80, 80));
    try testing.expectEqual(@as(u16, 24), healthPixels(40, 80));
    try testing.expectEqual(@as(u16, 1), healthPixels(1, 80));
    try testing.expectEqual(@as(u16, 0), healthPixels(0, 80));
    try testing.expectEqual(@as(u16, 48), healthPixels(200, 80));
}

test "the police icon: the bar's colours, the ground at its corners" {
    for ([_]usize{ 0, 7, 56, 63 }) |i| try testing.expectEqual(@as(u8, 2), police_icon[i]);
    for (police_icon) |p| try testing.expect(p == 2 or p == 6 or p >= 13);
}

/// A synthetic status bar's content, each tile a number (all its pixels): the bar's ground 0;
/// the font's letters from 1 (`glyphs`), its `->` 62, its end mark 63; the health bar's full
/// cells 60, empty 61; the fills 64 on.
const Fixture = struct {
    const glyphs = "-x0123456789ABCDEGIMNOPRSTUVY";
    const tiles: [80]art.Tile = blk: {
        var t: [80]art.Tile = undefined;
        for (&t, 0..) |*x, i| x.* = @splat(@intCast(i));
        break :blk t;
    };
    const font_glyphs = blk: {
        var g: [glyphs.len + 2]art.Glyph = undefined;
        for (glyphs, 0..) |c, i| g[i] = .{ .text = &[1]u8{c}, .tile = @intCast(i + 1) };
        g[glyphs.len] = .{ .text = "->", .tile = 62 };
        g[glyphs.len + 1] = .{ .text = "(ED)", .tile = 63 };
        break :blk g;
    };
    const font: art.Font = .{ .name = "f", .sheet = "f", .glyphs = &font_glyphs };
    const sheet: art.TileSheet = .{ .name = "f", .file = "", .tiles = &tiles };
    const fills: art.TileSheet = .{ .name = "fills", .file = "", .tiles = tiles[64..80] };
    const bar_cells: [40 * 4]art.Cell = @splat(.{ .tile = 0 });
    const status_bar: art.TileMap = .{ .name = "b", .file = "", .width = 40, .height = 4, .sheets = &.{}, .tiles = &tiles, .cells = &bar_cells };
    const health_cells_: [21]art.Cell = blk: {
        var c: [21]art.Cell = undefined;
        for (&c, 0..) |*x, i| x.* = .{ .tile = if (i < 10) 60 else if (i == 10) 64 else 61 };
        break :blk c;
    };
    const health: art.TileMap = .{ .name = "h", .file = "", .width = 21, .height = 1, .sheets = &.{}, .tiles = &tiles, .cells = &health_cells_ };
    const icon_cells: [4]art.Cell = @splat(.{ .tile = 0 });
    const icon: art.TileMap = .{ .name = "i", .file = "", .width = 2, .height = 2, .sheets = &.{}, .tiles = &tiles, .cells = &icon_cells };
    const player: records.BarPlayer = .{ .name = "1UP-", .name_at = .{ .x = 1, .y = 1 }, .score = .{ .x = 5, .y = 1 }, .health = .{ .x = 1, .y = 2 }, .lives = .{ .x = 12, .y = 1 }, .lives_mark = .{ .x = 11, .y = 2 }, .icon = .{ .x = 14, .y = 1 }, .specials = .{ .x = 17, .y = 1 }, .specials_mark = .{ .x = 16, .y = 2 } };
    const Screen = struct {
        status_bar: struct { players: [2]records.BarPlayer, time: Cell, score_most: u32 },
        continue_question: struct { question: []const u8, cursor: []const u8, game_over: []const u8 },
        name_entry: struct { label: []const u8, letters: []const []const u8 },
    };
    const screen: Screen = .{
        .status_bar = .{ .players = .{ player, player }, .time = .{ .x = 19, .y = 1 }, .score_most = 999_999 },
        .continue_question = .{ .question = "CONTINUE", .cursor = "->", .game_over = "GAME OVER" },
        .name_entry = .{ .label = "NAME", .letters = &.{ "A", "B", "(ED)" } },
    };
    const Assets = struct {
        screen: *const Screen,
        status_bar: *const art.TileMap,
        health_1: *const art.TileMap,
        health_2: *const art.TileMap,
        police_icon: *const art.TileMap,
        fills: *const art.TileSheet,
        text: struct { font: *const art.Font, sheet: *const art.TileSheet },
    };
    const assets: Assets = .{
        .screen = &screen,
        .status_bar = &status_bar,
        .health_1 = &health,
        .health_2 = &health,
        .police_icon = &icon,
        .fills = &fills,
        .text = .{ .font = &font, .sheet = &sheet },
    };

    /// Row `y` of the board as the fixture's tiles read: a glyph (`>` the cursor, `#` the end
    /// mark), `=` a full cell of the health bar, `.` an empty one, a to h a partial one's fill (its
    /// pixels), S the police icon.
    fn row(board: *const render.Board, y: i32) [40]u8 {
        var out: [40]u8 = undefined;
        for (&out, 0..) |*o, x| {
            const c = board.cell(@intCast(x), y);
            const t = board.tiles.items[c.tile];
            const n = t[0];
            o.* = if (t == &police_icon) 'S' else switch (n) {
                0 => ' ',
                1...glyphs.len => glyphs[n - 1],
                60 => '=',
                61 => '.',
                62 => '>',
                63 => '#',
                64...71 => 'a' + (n - 64),
                else => '?',
            };
        }
        return out;
    }
};

test "the bar of four: names, counts and health bars on their slots; a slot changed alone" {
    var board = try render.Board.init(testing.allocator, 40, 4);
    defer board.deinit();
    try board.drawMap(&Fixture.status_bar, 0, 0);
    var bar: round.Bar = .{ .party = .{ "1P ".*, "BOB".*, "CPU".*, "4P ".* } };
    bar.players[0] = .{ .playing = .{ .score = 0, .lives = 3, .specials = 1, .health = 80 } };
    bar.players[1] = .{ .playing = .{ .score = 0, .lives = 12, .specials = 0, .health = 40 } };
    bar.players[2] = .{ .asking = .{ .continues = 2, .new_game = false, .cursor = .yes, .answer = .yes } };
    try draw(&board, Fixture.assets, bar, null);
    try testing.expectEqualStrings(" 1P-  Sx1 BOB- Sx0    CONTINUE          ", &Fixture.row(&board, 1));
    try testing.expectEqualStrings(" ======x3 ===a..x9    >YES  x2          ", &Fixture.row(&board, 2));
    // Player 2 struck, its score up: its health bar alone changes; player 3 answers NO; player 4
    // is out of the game, its words shown.
    var next = bar;
    next.players[1].playing.health = 37;
    next.players[1].playing.score = 500;
    next.players[2] = .{ .out = .{ .name = true, .score = 0, .game_over = true } };
    next.players[3] = .{ .out = .{ .name = true, .score = 0, .game_over = true } };
    try draw(&board, Fixture.assets, next, bar);
    try testing.expectEqualStrings(" 1P-  Sx1 BOB- Sx0    CPU-GAME 4P- GAME ", &Fixture.row(&board, 1));
    try testing.expectEqualStrings(" ======x3 ==h...x9        OVER     OVER ", &Fixture.row(&board, 2));
    // The blink hides player 4's words: its name stays.
    var hidden = next;
    hidden.players[3].out.game_over = false;
    try draw(&board, Fixture.assets, hidden, next);
    try testing.expectEqualStrings(" 1P-  Sx1 BOB- Sx0    CPU-GAME 4P-      ", &Fixture.row(&board, 1));
    try testing.expectEqualStrings(" ======x3 ==h...x9        OVER          ", &Fixture.row(&board, 2));
}

test "a slot's question: the answer the cursor is on, the cursor's blink, the continues left" {
    var board = try render.Board.init(testing.allocator, 40, 4);
    defer board.deinit();
    try board.drawMap(&Fixture.status_bar, 0, 0);
    var bar: round.Bar = .{ .party = .{ "1P ".*, "2P ".*, "3P ".*, "4P ".* } };
    bar.players[0] = .{ .asking = .{ .continues = 3, .new_game = true, .cursor = null, .answer = .yes } };
    try draw(&board, Fixture.assets, bar, null);
    try testing.expectEqualStrings(" CONTINUE                               ", &Fixture.row(&board, 1));
    try testing.expectEqualStrings("  YES  x3                               ", &Fixture.row(&board, 2));
    // Down: the cursor on NO, shown.
    var next = bar;
    next.players[0].asking = .{ .continues = 3, .new_game = true, .cursor = .no, .answer = .no };
    try draw(&board, Fixture.assets, next, bar);
    try testing.expectEqualStrings(" >NO   x3                               ", &Fixture.row(&board, 2));
    // Its blink hides the cursor alone.
    var blink = next;
    blink.players[0].asking.cursor = null;
    try draw(&board, Fixture.assets, blink, next);
    try testing.expectEqualStrings("  NO   x3                               ", &Fixture.row(&board, 2));
    try testing.expectEqualStrings(" CONTINUE                               ", &Fixture.row(&board, 1));
}

test "a slot's name entry: the score over the label and the name's places" {
    var board = try render.Board.init(testing.allocator, 40, 4);
    defer board.deinit();
    try board.drawMap(&Fixture.status_bar, 0, 0);
    var bar: round.Bar = .{ .party = .{ "1P ".*, "2P ".*, "3P ".*, "4P ".* } };
    bar.players[3] = .{ .naming = .{ .score = 52_300, .places = .{ 1, 0, null } } };
    try draw(&board, Fixture.assets, bar, null);
    try testing.expectEqualStrings("                                 052300 ", &Fixture.row(&board, 1));
    try testing.expectEqualStrings("                               NAME BA  ", &Fixture.row(&board, 2));
    // The end mark at the third place.
    var next = bar;
    next.players[3].naming.places[2] = 2;
    try draw(&board, Fixture.assets, next, bar);
    try testing.expectEqualStrings("                               NAME BA# ", &Fixture.row(&board, 2));
}

test "a slot renamed (the CPU's player taken): drawn whole again, nothing of the old name left" {
    var board = try render.Board.init(testing.allocator, 40, 4);
    defer board.deinit();
    try board.drawMap(&Fixture.status_bar, 0, 0);
    var bar: round.Bar = .{ .party = .{ "CPU".*, "2P ".*, "3P ".*, "4P ".* } };
    bar.players[0] = .{ .playing = .{ .score = 0, .lives = 3, .specials = 1, .health = 80 } };
    try draw(&board, Fixture.assets, bar, null);
    try testing.expectEqualStrings(" CPU- Sx1", Fixture.row(&board, 1)[0..9]);
    var next = bar;
    next.party.?[0] = "1P ".*;
    try draw(&board, Fixture.assets, next, bar);
    try testing.expectEqualStrings(" 1P-  Sx1", Fixture.row(&board, 1)[0..9]);
}
