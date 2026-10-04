//! The game menu: 1 PLAYER, 2 PLAYERS, OPTIONS, after the title. It fades in; the arrow (the
//! font's `->`) blinks left of the chosen line, up and down move it ("menu move") from the fade's
//! start; once the fade is done, A, B, C or START chooses ("menu choose"), and after a tick the
//! menu fades out, then leaves for the character select or the options. Without a second pad, 2
//! PLAYERS is dimmed (the colours `menu/one_pad`) and the arrow skips it. Choosing OPTIONS with
//! pad 2 holding exactly A, B, C and right at the end of the fade opens the options' hidden lines.
const std = @import("std");
const flow = @import("../flow.zig");
const scene = @import("../scene.zig");
const library = @import("../library.zig");
const view = @import("../view.zig");
const render = @import("../render/root.zig");
const input = @import("../input.zig");
const art = @import("../content/art.zig");
const Setup = @import("../setup.zig").Setup;
const Colours = @import("colours.zig").Colours;

/// The arrow blinks: shown for 16 ticks, hidden for 16.
const blink_ticks = 16;
/// The arrow's place: two cells left of its line.
const arrow_cells = 2;

pub const Line = enum(u8) { one_player, two_players, options };

pub const Menu = struct {
    /// Ticks since the scene began (its set-up is tick 1).
    ticks: u16 = 0,
    phase: Phase = .setup,
    colours: Colours = .{},
    choice: Line = .one_player,
    /// The choice before the arrow's last move (without a second pad, the arrow skips 2 PLAYERS
    /// in its direction).
    previous: Line = .one_player,
    /// The lines the arrow can be on: all three, or not 2 PLAYERS without a second pad.
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

        pub fn line(a: *const Assets, l: Line) *const art.TileMap {
            return switch (l) {
                .one_player => a.one_player,
                .two_players => a.two_players,
                .options => a.options,
            };
        }
    };

    pub const layout: view.Layout = .{ .a = .{ .width = 64, .height = 32 } };

    pub fn start(_: *const Setup) Menu {
        return .{};
    }

    /// The arrow's top-left on the screen for line `l`: two cells left of the line's place.
    pub fn arrowAt(a: *const Assets, l: Line) struct { x: i32, y: i32 } {
        const p = a.line(l).place orelse art.Place{ .layer = .plane_a, .x = 0, .y = 0 };
        return .{ .x = (@as(i32, p.x) - arrow_cells) * 8, .y = @as(i32, p.y) * 8 };
    }

    pub fn tick(self: *Menu, turn: *scene.Turn, a: *const Assets) ?flow.Exit {
        self.ticks +|= 1;
        self.colours.latch();
        defer turn.frame = .{ .colours = self.colours.copy };
        self.shown_arrow = if (self.hidden) null else self.choice;
        switch (self.phase) {
            .setup => {
                turn.releasePads();
                turn.setup.hidden_lines = false;
                self.all_lines = turn.second_pad;
                self.colours.aim(if (turn.second_pad) a.two_pads else a.one_pad);
                self.colours.startFade(.target);
                self.blink_left = blink_ticks;
                // The menu's first step in the same tick: the arrow, the fade's first step.
                self.cursor(turn, a);
                _ = self.colours.stepFade();
                self.phase = .fade_in;
            },
            .fade_in => {
                self.cursor(turn, a);
                if (self.colours.stepFade()) self.phase = .choosing;
            },
            .choosing => {
                const p = turn.pressed.pad1;
                if (p.a or p.b or p.c or p.start) {
                    turn.play(a.choose);
                    self.phase = .chosen;
                } else {
                    // The lines follow the second pad as it comes and goes.
                    if (!self.all_lines and turn.second_pad) self.all_lines = true;
                    if (self.all_lines and !turn.second_pad) self.all_lines = false;
                    self.cursor(turn, a);
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
                .options => {
                    const p2 = turn.pads.pad2;
                    const code: input.Pad = .{ .a = true, .b = true, .c = true, .right = true };
                    turn.setup.hidden_lines = std.meta.eql(p2, code);
                    return .options;
                },
            },
        }
        return null;
    }

    /// The arrow: up and down move it, round the ends, with a sound; it blinks; without a second
    /// pad it does not stay on 2 PLAYERS.
    fn cursor(self: *Menu, turn: *scene.Turn, a: *const Assets) void {
        const p = turn.pressed.pad1;
        if (p.up or p.down) {
            turn.play(a.move);
            self.previous = self.choice;
            self.choice = if (p.up) switch (self.choice) {
                .one_player => .options,
                .two_players => .one_player,
                .options => .two_players,
            } else switch (self.choice) {
                .one_player => .two_players,
                .two_players => .options,
                .options => .one_player,
            };
        }
        self.blink_left -= 1;
        if (self.blink_left == 0) {
            self.blink_left = blink_ticks;
            self.hidden = !self.hidden;
        }
        if (!self.all_lines and self.choice == .two_players) {
            self.choice = if (self.previous == .options) .one_player else .options;
        }
    }

    pub fn draw(self: *const Menu, prev: ?*const Menu, v: *view.View, a: *const Assets) !void {
        if (prev == null) for (std.enums.values(Line)) |l| try v.board(.a).drawMapAtPlace(a.line(l));
        v.screen.colours = self.colours.shown;
        if (self.shown_arrow) |l| {
            const at = arrowAt(a, l);
            try v.sprites.append(v.gpa, render.Sprite.of(try v.glyphFrame(a.text, "->"), at.x, at.y));
        }
    }
};

test "without a second pad, 2 PLAYERS is dimmed and the arrow skips it; A chooses after the fade" {
    const cells = [_]art.Cell{.{ .tile = 0 }};
    const tiles = [_]art.Tile{@splat(1)};
    const glyphs = [_]art.Glyph{.{ .text = "->", .tile = 0 }};
    const font: art.Font = .{ .name = "main", .sheet = "fonts/main", .glyphs = &glyphs };
    const sheet: art.TileSheet = .{ .name = "main", .file = "main.png", .tiles = &tiles };
    var maps: [3]art.TileMap = undefined;
    for (&maps, 0..) |*m, i| m.* = .{ .name = "line", .file = "line.tmj", .width = 1, .height = 1, .sheets = &.{}, .tiles = &tiles, .cells = &cells, .place = .{ .layer = .plane_a, .x = 16, .y = @intCast(11 + 2 * i) } };
    var one_pad: art.Palette = .{ .name = "one_pad" };
    one_pad.colours[1][1] = .{ .r = 1, .g = 1, .b = 1 };
    const a: Menu.Assets = .{
        .one_player = &maps[0],
        .two_players = &maps[1],
        .options = &maps[2],
        .two_pads = &.{ .name = "two_pads" },
        .one_pad = &one_pad,
        .text = .{ .font = &font, .sheet = &sheet },
        .move = 1,
        .choose = 2,
    };
    var setup: Setup = .{};
    var m: Menu = .{};
    var turn: scene.Turn = .{ .setup = &setup, .second_pad = false };
    _ = m.tick(&turn, &a);
    try std.testing.expect(m.colours.palettes.target[1][1].eql(.{ .r = 1, .g = 1, .b = 1 }));
    // Down from 1 PLAYER lands on OPTIONS; down again on 1 PLAYER; up from it on OPTIONS.
    turn = .{ .setup = &setup, .second_pad = false, .pressed = .{ .pad1 = .{ .down = true } } };
    _ = m.tick(&turn, &a);
    try std.testing.expectEqual(Line.options, m.choice);
    try std.testing.expectEqual(@as(library.Sound, 1), turn.requests.slice()[0]);
    _ = m.tick(&turn, &a);
    try std.testing.expectEqual(Line.one_player, m.choice);
    turn = .{ .setup = &setup, .second_pad = false, .pressed = .{ .pad1 = .{ .up = true } } };
    _ = m.tick(&turn, &a);
    try std.testing.expectEqual(Line.options, m.choice);
    // A during the fade does nothing; after it, it chooses, and the fade out leads to OPTIONS.
    var exit: ?flow.Exit = null;
    while (exit == null) {
        turn = .{ .setup = &setup, .second_pad = false, .pressed = .{ .pad1 = .{ .a = true } } };
        exit = m.tick(&turn, &a);
        if (m.ticks < 64) try std.testing.expect(m.phase == .fade_in);
    }
    // Chosen at the 65th tick (after the 64 steps of the fade in), left 66 ticks later.
    try std.testing.expectEqual(flow.Exit.options, exit.?);
    try std.testing.expectEqual(@as(u16, 65 + 66), m.ticks);
}
