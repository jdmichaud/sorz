//! The game menu, after the title: the cartridge's 1 PLAYER, 2 PLAYERS, OPTIONS, or the lines of
//! another variant (variant.zig: SETTINGS after 2 PLAYERS in the extended game; START, SETTINGS,
//! OPTIONS in network play), one under the other from the cartridge's first line. It fades in; the
//! arrow (the font's `->`) blinks left of the chosen line, up and down move it ("menu move") from
//! the fade's start; once the fade is done, A, B, C or START chooses ("menu choose"), and after a
//! tick the menu fades out, then leaves for the character select or the options. SETTINGS is not a
//! way out: the settings open over the menu (game.zig), which goes on when they close. Without a
//! second pad, 2 PLAYERS is dimmed (the colours `menu/one_pad`) and the arrow skips it. Choosing
//! OPTIONS with pad 2 holding exactly A, B, C and right at the end of the fade opens the options'
//! hidden lines. The pad that drives the menu is the variant's (pad 1, or either player's).
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const input = @import("../input.zig");
const art = @import("../content/art.zig");
const variant = @import("../variant.zig");
const Setup = @import("../setup.zig").Setup;
const Colours = @import("colours.zig").Colours;

/// The arrow blinks: shown for 16 ticks, hidden for 16.
const blink_ticks = 16;
/// The arrow's place: two cells left of its line.
const arrow_cells = 2;

pub const Line = variant.MenuLine;

/// The most lines a menu has.
const most_lines = std.enums.values(Line).len;

/// The port's lines, which the cartridge's art does not have: written in its font, in the
/// colours of its bright lines.
fn word(l: Line) ?[]const u8 {
    return switch (l) {
        .start => "START",
        .settings => "SETTINGS",
        .one_player, .two_players, .options => null,
    };
}

pub const Menu = struct {
    /// Ticks since the scene began (its set-up is tick 1).
    ticks: u16 = 0,
    phase: Phase = .setup,
    colours: Colours = .{},
    /// The lines, from the top (the variant's, taken at the set-up), and how many.
    lines: [most_lines]Line = @splat(.one_player),
    line_count: u8 = 0,
    choice: Line = .one_player,
    /// The choice before the arrow's last move (without a second pad, the arrow skips 2 PLAYERS
    /// in its direction).
    previous: Line = .one_player,
    /// The lines the arrow can be on: all of them, or not 2 PLAYERS without a second pad.
    all_lines: bool = true,
    blink_left: u8 = 0,
    hidden: bool = false,
    /// The arrow as the picture shows it at this tick: the tick before's (null: hidden).
    shown_arrow: ?Line = null,

    pub const Phase = enum(u8) { setup, fade_in, choosing, chosen, fade_out, leaving };

    pub const Assets = struct {
        one_player: *const art.TileMap,
        two_players: *const art.TileMap,
        options: *const art.TileMap,
        two_pads: *const art.Palette,
        one_pad: *const art.Palette,
        text: library.Text,
        move: library.Sound,
        choose: library.Sound,
        pub const names = .{
            .one_player = "menu/one_player",
            .two_players = "menu/two_players",
            .options = "menu/options",
            .two_pads = "menu/two_pads",
            .one_pad = "menu/one_pad",
            .text = "fonts/main",
            .move = "menu move",
            .choose = "menu choose",
        };

        /// The cartridge's art of a line, if it has one.
        pub fn map(a: *const Assets, l: Line) ?*const art.TileMap {
            return switch (l) {
                .one_player => a.one_player,
                .two_players => a.two_players,
                .options => a.options,
                .start, .settings => null,
            };
        }

        /// The cell of the menu's `i`th line: the cartridge's first line's, and as many of its
        /// lines' steps down (each cartridge line at its own place).
        pub fn cellOf(a: *const Assets, i: usize) struct { x: i32, y: i32 } {
            const first = a.one_player.place orelse art.Place{ .layer = .plane_a, .x = 0, .y = 0 };
            const second = a.two_players.place orelse first;
            const step = @as(i32, second.y) - first.y;
            return .{ .x = first.x, .y = first.y + step * @as(i32, @intCast(i)) };
        }
    };

    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 } };

    pub fn start(_: *const Setup) Menu {
        return .{};
    }

    fn slice(self: *const Menu) []const Line {
        return self.lines[0..self.line_count];
    }

    fn indexOf(self: *const Menu, l: Line) usize {
        return std.mem.indexOfScalar(Line, self.slice(), l) orelse 0;
    }

    /// The arrow's top-left on the screen for line `l`: two cells left of the line's place.
    pub fn arrowAt(self: *const Menu, a: *const Assets, l: Line) struct { x: i32, y: i32 } {
        const c = a.cellOf(self.indexOf(l));
        return .{ .x = (c.x - arrow_cells) * 8, .y = c.y * 8 };
    }

    pub fn tick(self: *Menu, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.ticks +|= 1;
        self.colours.latch();
        defer turn.frame = .{ .colours = self.colours.copy, .first_line = true };
        self.shown_arrow = if (self.hidden) null else self.choice;
        const pad = turn.policies.menuPad(turn.pressed);
        switch (self.phase) {
            .setup => {
                turn.releasePads();
                turn.setup.hidden_lines = false;
                const lines = turn.policies.menuLines();
                @memcpy(self.lines[0..lines.len], lines);
                self.line_count = @intCast(lines.len);
                self.choice = lines[0];
                self.previous = lines[0];
                self.all_lines = turn.second_pad;
                self.colours.aim(if (turn.second_pad) a.two_pads else a.one_pad);
                self.colours.startFade(.target);
                self.blink_left = blink_ticks;
                // The menu's first step in the same tick: the arrow, the fade's first step.
                self.cursor(turn, turn.pressed.pad1, a);
                _ = self.colours.stepFade();
                self.phase = .fade_in;
            },
            .fade_in => {
                self.cursor(turn, pad.pressed, a);
                if (self.colours.stepFade()) self.phase = .choosing;
            },
            .choosing => {
                const p = pad.pressed;
                if (p.a or p.b or p.c or p.start) {
                    if (self.choice == .settings) {
                        // The settings open over the menu, which goes on when they close.
                        turn.settings = pad.player;
                    } else {
                        turn.play(a.choose);
                        self.phase = .chosen;
                    }
                } else {
                    // The lines follow the second pad as it comes and goes.
                    if (!self.all_lines and turn.second_pad) self.all_lines = true;
                    if (self.all_lines and !turn.second_pad) self.all_lines = false;
                    self.cursor(turn, p, a);
                }
            },
            // A tick to start the fade, which the arrow does not follow (it stays as it was).
            .chosen => {
                self.colours.startFade(.black);
                self.phase = .fade_out;
            },
            .fade_out => if (self.colours.stepFade()) {
                self.phase = .leaving;
            },
            .leaving => switch (self.choice) {
                .one_player => {
                    turn.setup.players = .one;
                    return .one_player;
                },
                .two_players => {
                    turn.setup.players = .two;
                    return .two_players;
                },
                // The players the game started with: the machines'.
                .start => return .play,
                .options => {
                    const p2 = turn.pads.pad2;
                    const code: input.Pad = .{ .a = true, .b = true, .c = true, .right = true };
                    turn.setup.hidden_lines = std.meta.eql(p2, code);
                    return .options;
                },
                .settings => unreachable,
            },
        }
        return null;
    }

    /// The arrow: up and down move it, round the ends, with a sound; it blinks; without a second
    /// pad it does not stay on 2 PLAYERS, but goes on in its direction.
    fn cursor(self: *Menu, turn: *scene.Turn, p: input.Pad, a: *const Assets) void {
        const lines = self.slice();
        const n = lines.len;
        if (p.up or p.down) {
            turn.play(a.move);
            self.previous = self.choice;
            const i = self.indexOf(self.choice);
            self.choice = lines[if (p.up) (i + n - 1) % n else (i + 1) % n];
        }
        self.blink_left -= 1;
        if (self.blink_left == 0) {
            self.blink_left = blink_ticks;
            self.hidden = !self.hidden;
        }
        if (!self.all_lines and self.choice == .two_players) {
            const i = self.indexOf(.two_players);
            const up = self.previous == lines[(i + 1) % n];
            self.choice = lines[if (up) (i + n - 1) % n else (i + 1) % n];
        }
    }

    pub fn draw(self: *const Menu, prev: ?*const Menu, v: *view.View, a: *const Assets) !void {
        if (prev == null) for (self.slice(), 0..) |l, i| {
            const c = a.cellOf(i);
            if (a.map(l)) |m| {
                try v.board(.a).drawMap(m, c.x, c.y);
            } else try v.write(.a, a.text, c.x, c.y, word(l).?, .{});
        };
        v.screen.colours = self.colours.shown;
        if (self.shown_arrow) |l| {
            const at = self.arrowAt(a, l);
            try v.sprites.append(v.gpa, render.Sprite.of(try v.glyphFrame(a.text, "->"), at.x, at.y));
        }
    }
};

const Fixture = struct {
    const cells = [_]art.Cell{.{ .tile = 0 }};
    const tiles = [_]art.Tile{@splat(1)};
    const glyphs = [_]art.Glyph{.{ .text = "->", .tile = 0 }};
    const font: art.Font = .{ .name = "main", .sheet = "fonts/main", .glyphs = &glyphs };
    const sheet: art.TileSheet = .{ .name = "main", .file = "main.png", .tiles = &tiles };
    const maps = blk: {
        var m: [3]art.TileMap = undefined;
        for (&m, 0..) |*x, i| x.* = .{ .name = "line", .file = "line.tmj", .width = 1, .height = 1, .sheets = &.{}, .tiles = &tiles, .cells = &cells, .place = .{ .layer = .plane_a, .x = 16, .y = 11 + 2 * i } };
        break :blk m;
    };
    const one_pad = blk: {
        var p: art.Palette = .{ .name = "one_pad" };
        p.colours[1][1] = .{ .r = 1, .g = 1, .b = 1 };
        break :blk p;
    };
    const assets: Menu.Assets = .{
        .one_player = &maps[0],
        .two_players = &maps[1],
        .options = &maps[2],
        .two_pads = &.{ .name = "two_pads" },
        .one_pad = &one_pad,
        .text = .{ .font = &font, .sheet = &sheet },
        .move = 1,
        .choose = 2,
    };
};

/// A tick of `m` with `pressed`, in variant `v`.
fn press(m: *Menu, setup: *Setup, v: variant.Variant, second_pad: bool, pressed: input.Pads) struct { exit: ?flow.Exit, turn: scene.Turn } {
    var turn: scene.Turn = .{ .setup = setup, .second_pad = second_pad, .pressed = pressed, .policies = &v.config().policies };
    const exit = m.tick(&turn, &Fixture.assets);
    return .{ .exit = exit, .turn = turn };
}

test "without a second pad, 2 PLAYERS is dimmed and the arrow skips it; A chooses after the fade" {
    const a = &Fixture.assets;
    var setup: Setup = .{};
    var m: Menu = .{};
    _ = press(&m, &setup, .original, false, .{});
    try std.testing.expect(m.colours.palettes.target[1][1].eql(.{ .r = 1, .g = 1, .b = 1 }));
    // Down from 1 PLAYER lands on OPTIONS; down again on 1 PLAYER; up from it on OPTIONS.
    const down = press(&m, &setup, .original, false, .{ .pad1 = .{ .down = true } });
    try std.testing.expectEqual(Line.options, m.choice);
    try std.testing.expectEqual(@as(library.Sound, 1), down.turn.requests.slice()[0]);
    _ = press(&m, &setup, .original, false, .{ .pad1 = .{ .down = true } });
    try std.testing.expectEqual(Line.one_player, m.choice);
    _ = press(&m, &setup, .original, false, .{ .pad1 = .{ .up = true } });
    try std.testing.expectEqual(Line.options, m.choice);
    // The cartridge's lines at their own places.
    try std.testing.expectEqual(@as(i32, 15 * 8), m.arrowAt(a, .options).y);
    // A during the fade does nothing; after it, it chooses, and the fade out leads to OPTIONS.
    var exit: ?flow.Exit = null;
    while (exit == null) {
        exit = press(&m, &setup, .original, false, .{ .pad1 = .{ .a = true } }).exit;
        if (m.ticks < 64) try std.testing.expect(m.phase == .fade_in);
    }
    // Chosen at the 65th tick (after the 64 steps of the fade in), left 66 ticks later.
    try std.testing.expectEqual(flow.Exit.options, exit.?);
    try std.testing.expectEqual(@as(u16, 65 + 66), m.ticks);
}

test "the extended menu: SETTINGS after 2 PLAYERS opens the settings and stays; OPTIONS a line lower" {
    const a = &Fixture.assets;
    var setup: Setup = .{};
    var m: Menu = .{};
    _ = press(&m, &setup, .extended, true, .{});
    try std.testing.expectEqualSlices(Line, &.{ .one_player, .two_players, .settings, .options }, m.slice());
    try std.testing.expectEqual(@as(i32, 15 * 8), m.arrowAt(a, .settings).y);
    try std.testing.expectEqual(@as(i32, 17 * 8), m.arrowAt(a, .options).y);
    while (m.phase != .choosing) _ = press(&m, &setup, .extended, true, .{});
    for ([_]Line{ .two_players, .settings, .options, .one_player }) |want| {
        _ = press(&m, &setup, .extended, true, .{ .pad1 = .{ .down = true } });
        try std.testing.expectEqual(want, m.choice);
    }
    // Without a second pad, 2 PLAYERS is passed in either direction.
    _ = press(&m, &setup, .extended, false, .{ .pad1 = .{ .down = true } });
    try std.testing.expectEqual(Line.settings, m.choice);
    _ = press(&m, &setup, .extended, false, .{ .pad1 = .{ .up = true } });
    try std.testing.expectEqual(Line.one_player, m.choice);
    _ = press(&m, &setup, .extended, true, .{ .pad1 = .{ .up = true } });
    _ = press(&m, &setup, .extended, true, .{ .pad1 = .{ .up = true } });
    try std.testing.expectEqual(Line.settings, m.choice);
    // SETTINGS: the settings asked for, by player 1; no sound, no way out, the menu goes on.
    const chosen = press(&m, &setup, .extended, true, .{ .pad1 = .{ .start = true } });
    try std.testing.expect(chosen.exit == null and chosen.turn.settings.? == 0 and chosen.turn.requests.len == 0);
    try std.testing.expectEqual(Menu.Phase.choosing, m.phase);
    _ = press(&m, &setup, .extended, true, .{ .pad1 = .{ .down = true } });
    var exit: ?flow.Exit = press(&m, &setup, .extended, true, .{ .pad1 = .{ .c = true } }).exit;
    while (exit == null) exit = press(&m, &setup, .extended, true, .{}).exit;
    try std.testing.expectEqual(flow.Exit.options, exit.?);
}

test "the network menu: START, SETTINGS, OPTIONS; either player's pad; START keeps the players" {
    const a = &Fixture.assets;
    var setup: Setup = .{ .players = .two };
    var m: Menu = .{};
    _ = press(&m, &setup, .network, true, .{});
    try std.testing.expectEqualSlices(Line, &.{ .start, .settings, .options }, m.slice());
    try std.testing.expectEqual(@as(i32, 11 * 8), m.arrowAt(a, .start).y);
    try std.testing.expectEqual(@as(i32, 15 * 8), m.arrowAt(a, .options).y);
    while (m.phase != .choosing) _ = press(&m, &setup, .network, true, .{});
    // Player 2 moves the arrow to SETTINGS and opens their own settings.
    _ = press(&m, &setup, .network, true, .{ .pad2 = .{ .down = true } });
    try std.testing.expectEqual(Line.settings, m.choice);
    const chosen = press(&m, &setup, .network, true, .{ .pad2 = .{ .a = true } });
    try std.testing.expectEqual(@as(?u1, 1), chosen.turn.settings);
    // Player 1 goes up to START and starts: the select with the two players.
    _ = press(&m, &setup, .network, true, .{ .pad1 = .{ .up = true } });
    var exit: ?flow.Exit = press(&m, &setup, .network, true, .{ .pad1 = .{ .b = true } }).exit;
    while (exit == null) exit = press(&m, &setup, .network, true, .{}).exit;
    try std.testing.expectEqual(flow.Exit.play, exit.?);
    try std.testing.expectEqual(@import("../setup.zig").Players.two, setup.players);
}
